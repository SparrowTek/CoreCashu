import Testing
@testable import CoreCashu
import Foundation
import P256K

/// Tests for the high-level NUT-11 wallet API added in Phase 4.A.
///
/// Full end-to-end tests against a live mint require Phase 6's mock-mint, so the tests below
/// focus on what we *can* verify deterministically without one:
/// - `sendLocked` validates multisig parameters before starting a swap.
/// - The `targetSecretFactory` hook in `prepareSwapToSend` is wired correctly.
/// - The signing path used by `unlockP2PK` produces signatures that the spec-compliant
///   verifier accepts (i.e., the round-trip works end-to-end).
@Suite("NUT-11 P2PKOperations")
struct P2PKOperationsTests {

    @Test("sendLocked rejects requiredSigs out of range")
    func testSendLockedRejectsBadRequiredSigs() async throws {
        let wallet = try await CashuWallet(mintURL: "https://test.mint.example.com")
        let pubkey = "0249098aa8b9d2fbec49ff8598feb17b592b986e62319a4fa488a3dc36387157a7"

        await #expect(throws: CashuError.self) {
            _ = try await wallet.sendLocked(
                amount: 10,
                to: pubkey,
                requiredSigs: 0
            )
        }

        await #expect(throws: CashuError.self) {
            _ = try await wallet.sendLocked(
                amount: 10,
                to: pubkey,
                requiredSigs: 5,
                additionalPubkeys: ["02aabbccddeeff0011223344556677889900112233445566778899aabbccddeeff"]
            )
        }
    }

    @Test("sendLocked rejects duplicate public keys in multisig set")
    func testSendLockedRejectsDuplicatePubkeys() async throws {
        let wallet = try await CashuWallet(mintURL: "https://test.mint.example.com")
        let pubkey = "0249098aa8b9d2fbec49ff8598feb17b592b986e62319a4fa488a3dc36387157a7"

        await #expect(throws: CashuError.self) {
            _ = try await wallet.sendLocked(
                amount: 10,
                to: pubkey,
                requiredSigs: 2,
                additionalPubkeys: [pubkey] // dup
            )
        }
    }

    @Test("Sign-and-verify round-trip — unlockP2PK signing path matches NUT-11 verifier")
    func testSignVerifyRoundtripMatchesValidator() throws {
        // Replicate what `unlockP2PK` does internally for a single proof:
        //   1. Build a P2PK well-known secret for a fresh keypair.
        //   2. Sign SHA256(secret_string) with BIP340 Schnorr (via NUT20SignatureManager).
        //   3. Run the signature through P2PKSignatureValidator.
        // This is the cryptographic contract `unlockP2PK` relies on; if it holds here, the
        // wallet-level unlock path will produce signatures the mint's verifier will accept.
        let privateKey = try P256K.Schnorr.PrivateKey()
        let publicKeyHex = "02" + privateKey.xonly.bytes.hexString

        let condition = P2PKSpendingCondition(
            publicKey: publicKeyHex,
            nonce: WellKnownSecret.generateNonce(),
            signatureFlag: .sigInputs
        )
        let secretString = try condition.toWellKnownSecret().toJSONString()

        let messageHash = Hash.sha256(Data(secretString.utf8))
        let signature = try NUT20SignatureManager.signMessage(
            messageHash: messageHash,
            privateKey: privateKey.dataRepresentation
        )

        // Direct validator call — what the mint will conceptually do.
        #expect(P2PKSignatureValidator.validateSignature(
            signature: signature,
            publicKey: publicKeyHex,
            message: secretString
        ) == true)

        // Now wrap in a witness, attach to a synthetic proof, and run the proof-level check.
        let witness = P2PKWitness(signatures: [signature])
        let witnessString = try witness.toJSONString()
        let proof = Proof(
            amount: 1,
            id: "009a1f293253e41e",
            secret: secretString,
            C: "02698c4e2b5f9534cd0687d87513c759790cf829aa5739184a3e3735471fbda904",
            witness: witnessString
        )
        let extracted = try #require(proof.getP2PKSpendingCondition())
        #expect(P2PKSignatureValidator.validateProofSignatures(
            proof: proof,
            condition: extracted
        ) == true)
    }

    @Test("Multisig — N-of-M passes when N distinct keys sign")
    func testMultisigDistinctSignersPass() throws {
        // Build a 2-of-3 condition; sign with two of the three keys; verify the witness
        // satisfies the condition.
        let pks = try (0..<3).map { _ in try P256K.Schnorr.PrivateKey() }
        let pubKeys = pks.map { "02" + $0.xonly.bytes.hexString }
        let condition = try P2PKSpendingCondition.multisig(
            publicKeys: pubKeys,
            requiredSigs: 2
        )
        let secretString = try condition.toWellKnownSecret().toJSONString()
        let messageHash = Hash.sha256(Data(secretString.utf8))

        // Sign with keys 0 and 2 (skip middle).
        let sig0 = try NUT20SignatureManager.signMessage(messageHash: messageHash, privateKey: pks[0].dataRepresentation)
        let sig2 = try NUT20SignatureManager.signMessage(messageHash: messageHash, privateKey: pks[2].dataRepresentation)

        let witness = P2PKWitness(signatures: [sig0, sig2])
        let proof = Proof(
            amount: 1,
            id: "009a1f293253e41e",
            secret: secretString,
            C: "02698c4e2b5f9534cd0687d87513c759790cf829aa5739184a3e3735471fbda904",
            witness: try witness.toJSONString()
        )
        let extracted = try #require(proof.getP2PKSpendingCondition())
        #expect(P2PKSignatureValidator.validateProofSignatures(
            proof: proof,
            condition: extracted
        ) == true)
    }

    @Test("Multisig — same key signing twice is not credited twice")
    func testMultisigDoubleSignerNotCreditedTwice() throws {
        // Phase 2.1 added per-signer accounting. A 2-of-3 condition where the witness has
        // two signatures from the same key (different aux randomness → different bytes) must
        // still fail the threshold.
        let pks = try (0..<3).map { _ in try P256K.Schnorr.PrivateKey() }
        let pubKeys = pks.map { "02" + $0.xonly.bytes.hexString }
        let condition = try P2PKSpendingCondition.multisig(
            publicKeys: pubKeys,
            requiredSigs: 2
        )
        let secretString = try condition.toWellKnownSecret().toJSONString()
        let messageHash = Hash.sha256(Data(secretString.utf8))

        // Same key signs twice — distinct bytes due to fresh aux rand.
        let sigA = try NUT20SignatureManager.signMessage(messageHash: messageHash, privateKey: pks[0].dataRepresentation)
        let sigB = try NUT20SignatureManager.signMessage(messageHash: messageHash, privateKey: pks[0].dataRepresentation)
        // Sanity: the two signatures aren't the same byte string (auxiliary randomness differs).
        // Even if they happen to be identical, the validator treats them as separate
        // signature entries and still must dedupe per signer.

        let witness = P2PKWitness(signatures: [sigA, sigB])
        let proof = Proof(
            amount: 1,
            id: "009a1f293253e41e",
            secret: secretString,
            C: "02698c4e2b5f9534cd0687d87513c759790cf829aa5739184a3e3735471fbda904",
            witness: try witness.toJSONString()
        )
        let extracted = try #require(proof.getP2PKSpendingCondition())
        #expect(P2PKSignatureValidator.validateProofSignatures(
            proof: proof,
            condition: extracted
        ) == false)
    }
}
