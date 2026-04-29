import Foundation
import Testing
@preconcurrency import P256K
@testable import CoreCashu

/// End-to-end exercises of NUT-11 (P2PK) and NUT-14 (HTLC) wallet operations against the
/// in-process ``MockMint``. These cover the live-mint integration explicitly deferred from
/// Phase 4 (see opus47.md "Phase 4 deferrals — NUT scope").
@Suite("MockMint locked-spending integration")
struct MockMintLockedSpendingTests {

    private static let mintURL = "https://mock.mint"

    private func makeWallet(_ mint: MockMint) async throws -> CashuWallet {
        let configuration = try WalletConfiguration(mintURL: Self.mintURL)
        let wallet = await CashuWallet(
            configuration: configuration,
            secureStore: InMemorySecureStore(),
            networking: mint.networking
        )
        try await wallet.initialize()
        return wallet
    }

    /// Generate a fresh secp256k1 keypair and return both halves as 32-byte / 33-byte hex.
    private func freshKeypair() throws -> (privateKeyHex: String, publicKeyHex: String) {
        let privateKey = try P256K.Signing.PrivateKey()
        // NUT-11 wants compressed-secp256k1 pubkeys (33 bytes, leading 02/03), which is what
        // `Signing.PublicKey.dataRepresentation` produces.
        return (
            privateKey.dataRepresentation.hexString,
            privateKey.publicKey.dataRepresentation.hexString
        )
    }

    private func mintProofs(_ wallet: CashuWallet, amount: Int) async throws {
        let quote = try await wallet.requestMintQuote(amount: amount)
        _ = try await wallet.mint(quoteID: quote.quote, amount: amount)
    }

    // MARK: - P2PK round-trip

    @Test("sendLocked → unlockP2PK round-trip moves balance to the recipient")
    func p2pkRoundTrip() async throws {
        let mint = try await MockMint()
        let sender = try await makeWallet(mint)
        let receiver = try await makeWallet(mint)
        try await mintProofs(sender, amount: 32)

        let keys = try freshKeypair()
        let lockedToken = try await sender.sendLocked(
            amount: 8,
            to: keys.publicKeyHex,
            memo: "p2pk-test"
        )

        // Sender's balance reflects the spent amount (with no fees in our mock).
        let senderBalanceAfterLock = try await sender.balance
        #expect(senderBalanceAfterLock == 32 - 8)

        // Recipient unlocks using the matching private key. Resulting proofs are anyone-can-spend.
        let unlocked = try await receiver.unlockP2PK(token: lockedToken, privateKey: keys.privateKeyHex)
        #expect(unlocked.reduce(0) { $0 + $1.amount } == 8)
        let receiverBalance = try await receiver.balance
        #expect(receiverBalance == 8)

        // Sanity-check: every proof in the locked token surfaced as a P2PK condition (i.e. the
        // wallet didn't accidentally fall through to the anyone-can-spend send path).
        let lockedProofs = lockedToken.token.flatMap { $0.proofs }
        #expect(!lockedProofs.isEmpty)
        for proof in lockedProofs {
            #expect(proof.getP2PKSpendingCondition() != nil, "proof should be P2PK-locked")
        }

        // The mint must now consider every locked input proof as spent.
        for proof in lockedProofs {
            let spent = try await mint.isProofSpent(proof)
            #expect(spent, "locked proofs should be spent on mint after recipient swaps")
        }
    }

    @Test("Witness signed by wrong key fails NUT-11 signature validation")
    func p2pkWrongKeyIsRejected() async throws {
        let mint = try await MockMint()
        let sender = try await makeWallet(mint)
        try await mintProofs(sender, amount: 16)

        let recipientKeys = try freshKeypair()
        let attackerKeys = try freshKeypair()
        let lockedToken = try await sender.sendLocked(amount: 4, to: recipientKeys.publicKeyHex)

        // For each locked proof, sign with the *wrong* private key and verify NUT-11's
        // `validateProofSignatures` rejects the resulting witness. The MockMint doesn't enforce
        // the witness check (that's NUT11Tests' P2PKSignatureValidator coverage); this asserts
        // the cryptographic gate that a real mint would apply.
        for proof in lockedToken.token.flatMap({ $0.proofs }) {
            guard let condition = proof.getP2PKSpendingCondition() else { continue }
            guard let attackerKey = Data(hexString: attackerKeys.privateKeyHex) else {
                Issue.record("attackerKey hex parse failed")
                continue
            }
            let messageHash = Hash.sha256(Data(proof.secret.utf8))
            let attackerSig = try NUT20SignatureManager.signMessage(
                messageHash: messageHash,
                privateKey: attackerKey
            )
            let witness = P2PKWitness(signatures: [attackerSig])
            let witnessString = try witness.toJSONString()
            let witnessedProof = Proof(
                amount: proof.amount,
                id: proof.id,
                secret: proof.secret,
                C: proof.C,
                witness: witnessString
            )
            let verdict = P2PKSignatureValidator.validateProofSignatures(
                proof: witnessedProof,
                condition: condition
            )
            #expect(verdict == false, "P2PK witness signed by attacker must not validate")
        }
    }

    @Test("sendLocked rejects malformed multisig parameters")
    func p2pkMultisigGuardrails() async throws {
        let mint = try await MockMint()
        let sender = try await makeWallet(mint)
        try await mintProofs(sender, amount: 16)
        let recipient = try freshKeypair()

        // requiredSigs must be in 1...keys.count
        await #expect(throws: CashuError.self) {
            _ = try await sender.sendLocked(
                amount: 4,
                to: recipient.publicKeyHex,
                requiredSigs: 0
            )
        }
        await #expect(throws: CashuError.self) {
            _ = try await sender.sendLocked(
                amount: 4,
                to: recipient.publicKeyHex,
                requiredSigs: 5,
                additionalPubkeys: []
            )
        }
        // Duplicate pubkeys are rejected.
        await #expect(throws: CashuError.self) {
            _ = try await sender.sendLocked(
                amount: 4,
                to: recipient.publicKeyHex,
                requiredSigs: 1,
                additionalPubkeys: [recipient.publicKeyHex]
            )
        }
    }

    // MARK: - HTLC round-trip

    @Test("createHTLC → redeemHTLC unlocks with the correct preimage")
    func htlcRoundTrip() async throws {
        let mint = try await MockMint()
        let sender = try await makeWallet(mint)
        let receiver = try await makeWallet(mint)
        try await mintProofs(sender, amount: 64)

        // Use a deterministic preimage so the test is reproducible without a debug print.
        let preimage = Data(repeating: 0x42, count: 32)
        let htlc = try await sender.createHTLC(amount: 16, preimage: preimage)
        #expect(htlc.amount == 16)
        #expect(htlc.preimage == preimage)
        #expect(htlc.hashLock == Hash.sha256(preimage).hexString)

        // The locked token round-trips through the V3 codec.
        let decoded = try CashuTokenUtils.deserializeToken(htlc.token)
        let lockedProofs = decoded.token.flatMap { $0.proofs }
        #expect(!lockedProofs.isEmpty)
        for proof in lockedProofs {
            // Each target proof should carry a NUT-10 well-known secret of kind HTLC.
            let wellKnown = proof.getWellKnownSecret()
            #expect(wellKnown?.kind == SpendingConditionKind.htlc)
        }

        let redeemed = try await receiver.redeemHTLC(token: htlc.token, preimage: preimage)
        #expect(redeemed.reduce(0) { $0 + $1.amount } == 16)
        let receiverBalance = try await receiver.balance
        #expect(receiverBalance == 16)

        // Sender's balance is now 64 - 16.
        let senderBalanceAfter = try await sender.balance
        #expect(senderBalanceAfter == 64 - 16)
    }

    @Test("checkHTLCStatus reflects locktime, hashlock, and amount")
    func htlcStatus() async throws {
        let mint = try await MockMint()
        let sender = try await makeWallet(mint)
        try await mintProofs(sender, amount: 32)

        let preimage = Data(repeating: 0x99, count: 32)
        let locktime = Date().addingTimeInterval(3600)
        let htlc = try await sender.createHTLC(
            amount: 8,
            preimage: preimage,
            locktime: locktime
        )

        let status = try await sender.checkHTLCStatus(token: htlc.token)
        #expect(status.hashLock == Hash.sha256(preimage).hexString)
        #expect(status.amount == 8)
        #expect(status.locktime != nil)
        #expect(status.isExpired == false)
    }

    // MARK: - Capability gating (Phase 7.3)

    @Test("sendLocked throws CashuError.unsupportedOperation when mint omits NUT-11")
    func sendLockedRejectedWhenP2PKUnadvertised() async throws {
        let mint = try await MockMint(configuration: .init(advertisedNUTsExclude: ["11"]))
        let wallet = try await makeWallet(mint)
        try await mintProofs(wallet, amount: 16)

        let keys = try freshKeypair()
        await #expect(throws: CashuError.self, "sendLocked must refuse when NUT-11 is missing") {
            _ = try await wallet.sendLocked(amount: 8, to: keys.publicKeyHex)
        }
    }

    @Test("createHTLC throws CashuError.unsupportedOperation when mint omits NUT-14")
    func createHTLCRejectedWhenHTLCUnadvertised() async throws {
        let mint = try await MockMint(configuration: .init(advertisedNUTsExclude: ["14"]))
        let wallet = try await makeWallet(mint)
        try await mintProofs(wallet, amount: 16)

        await #expect(throws: CashuError.self, "createHTLC must refuse when NUT-14 is missing") {
            _ = try await wallet.createHTLC(amount: 8, preimage: Data(repeating: 0x42, count: 32))
        }
    }

    @Test("requireCapability throws walletNotInitialized before initialize() runs")
    func requireCapabilityRejectsUninitializedWallet() async throws {
        // A fresh wallet that hasn't been initialized has no MintInfo / capability manager.
        // The contract is to throw `walletNotInitialized` rather than silently allowing the
        // capability check to pass.
        let configuration = try WalletConfiguration(mintURL: Self.mintURL)
        let wallet = await CashuWallet(
            configuration: configuration,
            secureStore: InMemorySecureStore()
        )
        await #expect(throws: CashuError.self) {
            try await wallet.requireCapability(.htlc)
        }
    }
}
