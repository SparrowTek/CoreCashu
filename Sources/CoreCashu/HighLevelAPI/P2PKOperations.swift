import Foundation
import P256K

/// High-level NUT-11 (P2PK) wallet operations.
///
/// These build on the cryptographic primitives validated in Phase 2.1 (BIP340 Schnorr over
/// secp256k1) and the swap-service `targetSecretFactory` hook added in Phase 4. The flow:
///
/// 1. Sender calls ``CashuWallet/sendLocked(amount:to:locktime:refundPubkeys:requiredSigs:additionalPubkeys:signatureFlag:memo:)``
///    which swaps available proofs into fresh outputs whose secrets carry the P2PK
///    well-known secret. The returned `CashuToken` is locked to the recipient's pubkey.
/// 2. Recipient calls ``CashuWallet/unlockP2PK(token:privateKey:)`` which signs each locked
///    proof's secret with BIP340 Schnorr, attaches the witness, and submits a swap to receive
///    fresh anyone-can-spend proofs.
public extension CashuWallet {

    /// Send a P2PK-locked token.
    ///
    /// - Parameters:
    ///   - amount: Amount to lock for the recipient.
    ///   - publicKey: Recipient's secp256k1 public key in hex (compressed 33-byte
    ///     `02...`/`03...` form, or x-only 32-byte form).
    ///   - locktime: Optional Unix-timestamp lock. Until expiry, only the recipient (or any
    ///     `additionalPubkeys`) can spend; after expiry, refund keys (if any) take over.
    ///   - refundPubkeys: Public keys that can spend after `locktime` expires.
    ///   - requiredSigs: For multisig: minimum signatures from `[publicKey] + additionalPubkeys`.
    ///   - additionalPubkeys: Extra pubkeys included alongside `publicKey` for multisig.
    ///   - signatureFlag: NUT-11 signature flag. Defaults to `.sigInputs`.
    ///   - memo: Optional memo carried in the token wrapper.
    /// - Returns: A `CashuToken` whose proofs are P2PK-locked to the supplied condition.
    /// - Throws: `CashuError.walletNotInitialized` if the wallet is not ready,
    ///   `CashuError.invalidAmount` if `amount <= 0`,
    ///   `CashuError.invalidSpendingCondition(_:)` for malformed multisig parameters.
    func sendLocked(
        amount: Int,
        to publicKey: String,
        locktime: Int? = nil,
        refundPubkeys: [String] = [],
        requiredSigs: Int = 1,
        additionalPubkeys: [String] = [],
        signatureFlag: SignatureFlag = .sigInputs,
        memo: String? = nil
    ) async throws -> CashuToken {
        guard isReady else { throw CashuError.walletNotInitialized }
        try requireCapability(.p2pk, operation: "Send P2PK-locked token")
        guard amount > 0 else { throw CashuError.invalidAmount }

        // Validate multisig coherence up-front so the swap is not started against an obviously-
        // bad condition. Mirrors `P2PKSpendingCondition.multisig` rules.
        let allKeys = [publicKey] + additionalPubkeys
        guard requiredSigs > 0, requiredSigs <= allKeys.count else {
            throw CashuError.invalidSpendingCondition(
                "requiredSigs (\(requiredSigs)) must be in 1...\(allKeys.count)"
            )
        }
        guard Set(allKeys).count == allKeys.count else {
            throw CashuError.invalidSpendingCondition("public keys must be unique")
        }

        guard let swapService = await getSwapService() else {
            throw CashuError.walletNotInitialized
        }

        // The factory is invoked once per target output. Each call produces a NUT-11 secret
        // string with a fresh nonce so the per-output randomness required by the spec is
        // preserved while every target output enforces the same locking condition.
        let lockedPublicKey = publicKey
        let lockedLocktime = locktime
        let lockedRefundPubkeys = refundPubkeys
        let lockedRequiredSigs = requiredSigs
        let lockedAdditionalPubkeys = additionalPubkeys
        let lockedSignatureFlag = signatureFlag
        let factory: @Sendable () throws -> String = {
            let condition = P2PKSpendingCondition(
                publicKey: lockedPublicKey,
                nonce: WellKnownSecret.generateNonce(),
                signatureFlag: lockedSignatureFlag,
                requiredSigs: lockedRequiredSigs,
                additionalPubkeys: lockedAdditionalPubkeys,
                locktime: lockedLocktime,
                refundPubkeys: lockedRefundPubkeys
            )
            return try condition.toWellKnownSecret().toJSONString()
        }

        let availableProofs = try await getAvailableProofs()
        let preparation = try await swapService.prepareSwapToSend(
            availableProofs: availableProofs,
            targetAmount: amount,
            unit: configuration.unit,
            at: configuration.mintURL,
            targetSecretFactory: factory
        )

        try await markPendingSpent(preparation.inputProofs)
        do {
            let swapResult = try await swapService.executeCompleteSwap(
                preparation: preparation,
                at: configuration.mintURL
            )

            let (sendProofs, changeProofs) = try lockedPartition(
                swapResult.newProofs,
                targetAmount: amount,
                targetSecrets: preparation.targetSecrets
            )

            try await finalizePendingSpent(preparation.inputProofs)
            try await markSpent(preparation.inputProofs)
            try await removeProofs(preparation.inputProofs)

            if !changeProofs.isEmpty {
                try await addProofs(changeProofs)
            }

            return CashuToken(
                token: [TokenEntry(mint: configuration.mintURL, proofs: sendProofs)],
                unit: configuration.unit,
                memo: memo
            )
        } catch {
            try await rollbackPendingSpent(preparation.inputProofs)
            throw error
        }
    }

    /// Unlock and receive a P2PK-locked token.
    ///
    /// For each locked proof in the token, signs `proof.secret` (UTF-8) under BIP340 Schnorr
    /// with the supplied private key, attaches the resulting witness, and submits a swap. The
    /// mint validates the witness against the spending condition and issues fresh
    /// anyone-can-spend proofs.
    ///
    /// - Parameters:
    ///   - token: A P2PK-locked token (as returned by ``sendLocked(amount:to:locktime:refundPubkeys:requiredSigs:additionalPubkeys:signatureFlag:memo:)``).
    ///   - privateKey: 32-byte secp256k1 private key, hex-encoded.
    /// - Returns: The unlocked proofs added to the wallet.
    /// - Throws: `CashuError.invalidMintConfiguration` if the token is for a different mint;
    ///   `CashuError.invalidHexString` for a malformed private key;
    ///   network/swap errors propagated from the mint.
    func unlockP2PK(token: CashuToken, privateKey: String) async throws -> [Proof] {
        guard isReady else { throw CashuError.walletNotInitialized }
        try requireCapability(.p2pk, operation: "Unlock P2PK-locked token")
        guard let swapService = await getSwapService() else {
            throw CashuError.walletNotInitialized
        }
        guard let privateKeyData = Data(hexString: privateKey), privateKeyData.count == 32 else {
            throw CashuError.invalidHexString
        }

        var allUnlocked: [Proof] = []

        for tokenEntry in token.token {
            guard tokenEntry.mint == configuration.mintURL else {
                throw CashuError.invalidMintConfiguration
            }

            // Build witnesses for any P2PK-locked proofs; pass through other proofs unchanged
            // so the same code path can handle a mixed token.
            var witnessedProofs: [Proof] = []
            for proof in tokenEntry.proofs {
                if proof.getP2PKSpendingCondition() != nil {
                    let messageHash = Hash.sha256(Data(proof.secret.utf8))
                    let signature = try NUT20SignatureManager.signMessage(
                        messageHash: messageHash,
                        privateKey: privateKeyData
                    )
                    let witness = P2PKWitness(signatures: [signature])
                    let witnessString = try witness.toJSONString()
                    witnessedProofs.append(Proof(
                        amount: proof.amount,
                        id: proof.id,
                        secret: proof.secret,
                        C: proof.C,
                        witness: witnessString,
                        dleq: proof.dleq
                    ))
                } else {
                    witnessedProofs.append(proof)
                }
            }

            let swapResult = try await swapService.swapToReceive(
                proofs: witnessedProofs,
                at: configuration.mintURL
            )
            try await addProofs(swapResult.newProofs)
            allUnlocked.append(contentsOf: swapResult.newProofs)
        }

        return allUnlocked
    }
}

// MARK: - Internal proof-management bridges
//
// `CashuWallet`'s proof manager is private to the actor; these tiny accessors expose the
// operations `sendLocked` / `unlockP2PK` need without relaxing the broader visibility.

extension CashuWallet {
    func getAvailableProofs() async throws -> [Proof] {
        try await proofManager.getAvailableProofs()
    }

    func markPendingSpent(_ proofs: [Proof]) async throws {
        try await proofManager.markAsPendingSpent(proofs)
    }

    func finalizePendingSpent(_ proofs: [Proof]) async throws {
        try await proofManager.finalizePendingSpent(proofs)
    }

    func rollbackPendingSpent(_ proofs: [Proof]) async throws {
        try await proofManager.rollbackPendingSpent(proofs)
    }

    func markSpent(_ proofs: [Proof]) async throws {
        try await proofManager.markAsSpent(proofs)
    }

    func removeProofs(_ proofs: [Proof]) async throws {
        try await proofManager.removeProofs(proofs)
    }

    func addProofs(_ proofs: [Proof]) async throws {
        try await proofManager.addProofs(proofs)
    }

    /// Partition swap outputs by `targetSecrets`. Distinct from the wallet's private
    /// `partitionSwapOutputs` (denomination-aware) because the locked path always knows its
    /// target proofs by secret content.
    func lockedPartition(
        _ newProofs: [Proof],
        targetAmount: Int,
        targetSecrets: Set<String>
    ) throws -> (sendProofs: [Proof], changeProofs: [Proof]) {
        var send: [Proof] = []
        var change: [Proof] = []
        for proof in newProofs {
            if targetSecrets.contains(proof.secret) {
                send.append(proof)
            } else {
                change.append(proof)
            }
        }
        let sendTotal = send.reduce(0) { $0 + $1.amount }
        guard sendTotal == targetAmount else {
            throw CashuError.invalidState("Locked swap output partition mismatch")
        }
        return (send, change)
    }
}
