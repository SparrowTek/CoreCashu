import Foundation
import P256K

/// High-level NUT-14 (Hash Time-Locked Contract) wallet operations.
///
/// Phase 4 of `opus47.md` finished the wiring: target outputs are now actually HTLC-locked
/// (the `targetSecretFactory` hook on `SwapService.prepareSwapToSend` carries the HTLC
/// well-known secret), and redemption/refund attach a real `HTLCWitness` to each proof
/// before swap. The previous version generated the secret and then discarded it.
public extension CashuWallet {

    // MARK: - HTLC Creation

    /// Create an HTLC-locked token.
    ///
    /// - Parameters:
    ///   - amount: Amount to lock under the hash.
    ///   - preimage: Optional 32-byte preimage. If nil, a fresh CSPRNG preimage is generated.
    ///   - locktime: Optional locktime after which `refundKey` may spend.
    ///   - refundKey: Public key allowed to spend after `locktime`.
    ///   - authorizedKeys: Optional pubkeys that must co-sign alongside revealing the preimage.
    /// - Returns: ``HTLCToken`` containing the locked CashuToken (V3-serialized) plus the
    ///   metadata the recipient needs to redeem.
    func createHTLC(
        amount: Int,
        preimage: Data? = nil,
        locktime: Date? = nil,
        refundKey: String? = nil,
        authorizedKeys: [String]? = nil
    ) async throws -> HTLCToken {
        guard isReady else { throw CashuError.walletNotInitialized }
        try requireCapability(.htlc, operation: "Create HTLC-locked token")
        guard amount > 0 else { throw CashuError.invalidAmount }
        guard let swapService = await getSwapService() else {
            throw CashuError.walletNotInitialized
        }

        // SECURITY: preimages must come from a CSPRNG. Validate any caller-supplied preimage
        // is at least 32 bytes (the spec requires exactly 32; HTLCCreator rejects others).
        let actualPreimage: Data
        if let preimage {
            guard preimage.count == 32 else { throw CashuError.invalidPreimage }
            actualPreimage = preimage
        } else {
            actualPreimage = try HTLCCreator.generatePreimage()
        }
        let hashLockHex = Hash.sha256(actualPreimage).hexString

        let pubkeys = authorizedKeys ?? []
        let locktimeUnix: Int64? = locktime.map { Int64($0.timeIntervalSince1970) }

        // The factory is invoked once per target output. `HTLCCreator.createHTLCSecret`
        // generates a fresh nonce per call, satisfying NUT-10's per-output-randomness rule.
        let factory: @Sendable () throws -> String = {
            try HTLCCreator.createHTLCSecret(
                preimage: actualPreimage,
                pubkeys: pubkeys,
                locktime: locktimeUnix,
                refundKey: refundKey,
                sigflag: .sigInputs
            )
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
        let lockedTokenString: String
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

            let lockedToken = CashuToken(
                token: [TokenEntry(mint: configuration.mintURL, proofs: sendProofs)],
                unit: configuration.unit
            )
            lockedTokenString = try CashuTokenUtils.serializeToken(lockedToken)
        } catch {
            try await rollbackPendingSpent(preparation.inputProofs)
            throw error
        }

        return HTLCToken(
            token: lockedTokenString,
            preimage: actualPreimage,
            hashLock: hashLockHex,
            locktime: locktime,
            refundKey: refundKey,
            authorizedKeys: authorizedKeys,
            amount: amount
        )
    }

    // MARK: - HTLC Redemption

    /// Redeem an HTLC-locked token by revealing the preimage.
    ///
    /// - Parameters:
    ///   - token: The serialized HTLC-locked CashuToken (cashuA/cashuB).
    ///   - preimage: The 32-byte preimage that hashes to the HTLC's hash lock.
    ///   - signatures: Optional signatures, required if the HTLC was created with
    ///     `authorizedKeys`. The caller is responsible for producing these (sign each
    ///     `proof.secret` under BIP340 Schnorr with the corresponding key).
    /// - Returns: The unlocked anyone-can-spend proofs added to the wallet.
    func redeemHTLC(
        token: String,
        preimage: Data,
        signatures: [String]? = nil
    ) async throws -> [Proof] {
        guard isReady else { throw CashuError.walletNotInitialized }
        try requireCapability(.htlc, operation: "Redeem HTLC-locked token")
        guard let swapService = await getSwapService() else {
            throw CashuError.walletNotInitialized
        }

        let cashuToken = try CashuTokenUtils.deserializeToken(token)
        let preimageHex = preimage.hexString

        var allUnlocked: [Proof] = []
        for tokenEntry in cashuToken.token {
            guard tokenEntry.mint == configuration.mintURL else {
                throw CashuError.invalidMintConfiguration
            }

            // Pre-flight: verify locally that the preimage hashes to each proof's hash lock.
            // This catches obvious bugs before we hit the mint and pay round-trip latency.
            for proof in tokenEntry.proofs {
                let witness = HTLCWitness(preimage: preimageHex, signatures: signatures ?? [])
                _ = try HTLCVerifier.verifyHTLC(proof: proof, witness: witness)
            }

            // Attach the witness to every locked proof. Non-HTLC proofs in a mixed token are
            // passed through untouched.
            let witnessedProofs = tokenEntry.proofs.map { proof -> Proof in
                guard let secret = try? WellKnownSecret.fromString(proof.secret), secret.isHTLC else {
                    return proof
                }
                let witness = HTLCWitness(preimage: preimageHex, signatures: signatures ?? [])
                let witnessString = (try? Self.encodeHTLCWitness(witness)) ?? ""
                return Proof(
                    amount: proof.amount,
                    id: proof.id,
                    secret: proof.secret,
                    C: proof.C,
                    witness: witnessString,
                    dleq: proof.dleq
                )
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

    /// Refund an expired HTLC by signing with the refund key.
    ///
    /// - Parameters:
    ///   - token: The serialized HTLC-locked CashuToken.
    ///   - refundPrivateKey: 32-byte secp256k1 private key, hex-encoded, that corresponds to
    ///     the HTLC's `refund` tag pubkey.
    /// - Returns: The refunded anyone-can-spend proofs added to the wallet.
    func refundHTLC(
        token: String,
        refundPrivateKey: String
    ) async throws -> [Proof] {
        guard isReady else { throw CashuError.walletNotInitialized }
        try requireCapability(.htlc, operation: "Refund expired HTLC")
        guard let swapService = await getSwapService() else {
            throw CashuError.walletNotInitialized
        }
        guard let privateKeyData = Data(hexString: refundPrivateKey), privateKeyData.count == 32 else {
            throw CashuError.invalidHexString
        }

        let cashuToken = try CashuTokenUtils.deserializeToken(token)
        var allRefunded: [Proof] = []

        for tokenEntry in cashuToken.token {
            guard tokenEntry.mint == configuration.mintURL else {
                throw CashuError.invalidMintConfiguration
            }

            let witnessedProofs = try tokenEntry.proofs.map { proof -> Proof in
                // Sign each proof's secret with the refund key (BIP340 Schnorr per NUT-14).
                let messageHash = Hash.sha256(Data(proof.secret.utf8))
                let signature = try NUT20SignatureManager.signMessage(
                    messageHash: messageHash,
                    privateKey: privateKeyData
                )
                let witness = HTLCWitness(preimage: "", signatures: [signature])
                return Proof(
                    amount: proof.amount,
                    id: proof.id,
                    secret: proof.secret,
                    C: proof.C,
                    witness: try Self.encodeHTLCWitness(witness),
                    dleq: proof.dleq
                )
            }

            let swapResult = try await swapService.swapToReceive(
                proofs: witnessedProofs,
                at: configuration.mintURL
            )
            try await addProofs(swapResult.newProofs)
            allRefunded.append(contentsOf: swapResult.newProofs)
        }
        return allRefunded
    }

    // MARK: - HTLC Status

    /// Check the on-mint status (and decode the local locktime) of an HTLC token.
    func checkHTLCStatus(token: String) async throws -> HTLCStatus {
        guard isReady else { throw CashuError.walletNotInitialized }
        try requireCapability(.htlc, operation: "Check HTLC token status")

        let cashuToken = try CashuTokenUtils.deserializeToken(token)
        guard let tokenEntry = cashuToken.token.first else {
            throw CashuError.invalidToken
        }

        let batchResult = try await checkProofStates(tokenEntry.proofs)

        // Decode the HTLC fields from the *first* locked proof. If none are HTLC, return a
        // status with empty fields and let the caller decide whether the token is even an
        // HTLC.
        var hashLock = ""
        var locktimeDate: Date?
        var refundKey: String?
        var authorizedKeys: [String]?
        if let firstHTLC = tokenEntry.proofs.first(where: {
            (try? WellKnownSecret.fromString($0.secret))?.isHTLC == true
        }), let secret = try? WellKnownSecret.fromString(firstHTLC.secret) {
            hashLock = secret.hashLock ?? ""
            if let locktimeTag = secret.secretData.tags?.first(where: { $0.first == "locktime" }),
               locktimeTag.count >= 2,
               let locktimeUnix = Double(locktimeTag[1]) {
                locktimeDate = Date(timeIntervalSince1970: locktimeUnix)
            }
            refundKey = secret.refundPublicKey
            if let pubkeysTag = secret.secretData.tags?.first(where: { $0.first == "pubkeys" }),
               pubkeysTag.count > 1 {
                authorizedKeys = Array(pubkeysTag.dropFirst())
            }
        }

        let isExpired: Bool = locktimeDate.map { $0 < Date() } ?? false
        let isSpent = batchResult.spentProofs.count == tokenEntry.proofs.count
        let isPending = !batchResult.pendingProofs.isEmpty

        return HTLCStatus(
            hashLock: hashLock,
            amount: tokenEntry.proofs.totalValue,
            locktime: locktimeDate,
            isExpired: isExpired,
            isSpent: isSpent,
            isPending: isPending,
            refundKey: refundKey,
            authorizedKeys: authorizedKeys
        )
    }
}

// MARK: - HTLC Result Types

/// Represents an HTLC-locked token with metadata
public struct HTLCToken: Sendable {
    /// The locked Cashu token
    public let token: String

    /// The secret preimage
    public let preimage: Data

    /// The hash lock (SHA256 of preimage)
    public let hashLock: String

    /// Optional locktime for refunds
    public let locktime: Date?

    /// Optional refund public key
    public let refundKey: String?

    /// Optional authorized public keys
    public let authorizedKeys: [String]?

    /// Amount locked in the HTLC
    public let amount: Int
}

// MARK: - HTLCWitness JSON helpers

extension HTLCWitness {
    /// Sorted-key JSON encoding of the witness, suitable for `Proof.witness`.
    fileprivate func toJSONString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CashuError.serializationFailed
        }
        return string
    }
}

extension CashuWallet {
    fileprivate static func encodeHTLCWitness(_ witness: HTLCWitness) throws -> String {
        try witness.toJSONString()
    }
}

/// Status information about an HTLC
public struct HTLCStatus: Sendable {
    /// The hash lock of the HTLC
    public let hashLock: String

    /// Amount locked in the HTLC
    public let amount: Int

    /// Locktime if set
    public let locktime: Date?

    /// Whether the locktime has expired
    public let isExpired: Bool

    /// Whether the HTLC has been spent
    public let isSpent: Bool

    /// Whether the HTLC is pending
    public let isPending: Bool

    /// Refund public key if set
    public let refundKey: String?

    /// Authorized public keys if set
    public let authorizedKeys: [String]?
}
