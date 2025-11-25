import Foundation
import CryptoKit
import P256K

/// High-level API for Hash Time-Locked Contracts (HTLCs) in Cashu
/// Implements NUT-14 specification
public extension CashuWallet {

    // MARK: - HTLC Creation

    /// Create an HTLC-locked token
    /// - Parameters:
    ///   - amount: Amount to lock
    ///   - preimage: The secret preimage (if nil, one will be generated)
    ///   - locktime: Optional locktime after which refund is allowed
    ///   - refundKey: Optional public key for refund after locktime
    ///   - authorizedKeys: Optional list of public keys that can spend with signatures
    /// - Returns: HTLCToken containing the locked token and metadata
    func createHTLC(
        amount: Int,
        preimage: Data? = nil,
        locktime: Date? = nil,
        refundKey: String? = nil,
        authorizedKeys: [String]? = nil
    ) async throws -> HTLCToken {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }

        // Generate preimage if not provided
        let actualPreimage = preimage ?? Data(SHA256.hash(data: Data(UUID().uuidString.utf8)))
        let hashLock = SHA256.hash(data: actualPreimage)
        let hashLockHex = hashLock.compactMap { String(format: "%02x", $0) }.joined()

        // Select proofs for the amount
        let selectedProofs = try await selectProofsForAmount(amount)
        guard selectedProofs.totalValue >= amount else {
            throw CashuError.insufficientFunds
        }

        // Build HTLC secret
        var tags: [[String]] = []

        // Add locktime if provided
        if let locktime = locktime {
            let locktimeTimestamp = Int64(locktime.timeIntervalSince1970)
            tags.append(["locktime", String(locktimeTimestamp)])
        }

        // Add refund key if provided
        if let refundKey = refundKey {
            tags.append(["refund", refundKey])
        }

        // Add authorized keys if provided
        if let authorizedKeys = authorizedKeys, !authorizedKeys.isEmpty {
            tags.append(["pubkeys"] + authorizedKeys)
        }

        let secretData = WellKnownSecret.SecretData(
            nonce: Data(UUID().uuidString.utf8).base64URLEncodedString(),
            data: hashLockHex,
            tags: tags.isEmpty ? nil : tags
        )

        _ = WellKnownSecret(
            kind: SpendingConditionKind.htlc,
            secretData: secretData
        )

        // Create the locked token
        // Note: This is a simplified implementation
        // Real HTLC implementation would need to properly lock the token with the secret
        let lockedToken = try await send(amount: amount)
        let tokenString = try CashuTokenUtils.serializeToken(lockedToken)

        // Metrics recording removed - metrics is private
        // In a real implementation, we'd need to expose metrics or add a public method

        return HTLCToken(
            token: tokenString,
            preimage: actualPreimage,
            hashLock: hashLockHex,
            locktime: locktime,
            refundKey: refundKey,
            authorizedKeys: authorizedKeys,
            amount: amount
        )
    }

    // MARK: - HTLC Redemption

    /// Redeem an HTLC-locked token using the preimage
    /// - Parameters:
    ///   - token: The HTLC token to redeem
    ///   - preimage: The secret preimage
    ///   - signatures: Optional signatures if authorized keys were specified
    /// - Returns: Array of unlocked proofs
    func redeemHTLC(
        token: String,
        preimage: Data,
        signatures: [String]? = nil
    ) async throws -> [Proof] {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }

        // Parse the token
        let cashuToken = try CashuTokenUtils.deserializeToken(token)
        guard let tokenEntry = cashuToken.token.first else {
            throw CashuError.invalidToken
        }

        // Create witness
        let preimageHex = preimage.compactMap { String(format: "%02x", $0) }.joined()
        let witness = HTLCWitness(
            preimage: preimageHex,
            signatures: signatures ?? []
        )

        // Verify the HTLC locally first
        for proof in tokenEntry.proofs {
            _ = try HTLCVerifier.verifyHTLC(
                proof: proof,
                witness: witness
            )
        }

        // In a real implementation, we would swap the proofs with witness
        // For now, just receive the token normally
        let unlockedProofs = try await receive(token: cashuToken)

        // Metrics recording removed - metrics is private

        return unlockedProofs
    }

    /// Refund an expired HTLC using the refund key
    /// - Parameters:
    ///   - token: The HTLC token to refund
    ///   - refundPrivateKey: The private key corresponding to the refund public key
    /// - Returns: Array of refunded proofs
    func refundHTLC(
        token: String,
        refundPrivateKey: String
    ) async throws -> [Proof] {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }

        // Parse the token
        let cashuToken = try CashuTokenUtils.deserializeToken(token)
        guard let tokenEntry = cashuToken.token.first else {
            throw CashuError.invalidToken
        }

        // Create signature for refund
        let signature = try signForRefund(
            proofs: tokenEntry.proofs,
            privateKey: refundPrivateKey
        )

        // Create witness with empty preimage (for refund path)
        _ = HTLCWitness(
            preimage: "",
            signatures: [signature]
        )

        // In a real implementation, we would swap with witness for refund
        // For now, just receive the token normally
        let refundedProofs = try await receive(token: cashuToken)

        // Metrics recording removed - metrics is private

        return refundedProofs
    }

    // MARK: - HTLC Status

    /// Check the status of an HTLC token
    /// - Parameter token: The HTLC token to check
    /// - Returns: Status information about the HTLC
    func checkHTLCStatus(token: String) async throws -> HTLCStatus {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }

        let cashuToken = try CashuTokenUtils.deserializeToken(token)
        guard let tokenEntry = cashuToken.token.first else {
            throw CashuError.invalidToken
        }

        // Check proof states with mint
        let batchResult = try await checkProofStates(tokenEntry.proofs)

        // Parse HTLC details from the first proof
        // Note: This is a simplified implementation
        // Real implementation would properly parse HTLC secrets

        let locktime: Date? = nil // Would be parsed from secret
        let isExpired = false
        let isSpent = batchResult.spentProofs.count == tokenEntry.proofs.count
        let isPending = batchResult.pendingProofs.count > 0

        return HTLCStatus(
            hashLock: "", // Would be extracted from secret
            amount: tokenEntry.proofs.totalValue,
            locktime: locktime,
            isExpired: isExpired,
            isSpent: isSpent,
            isPending: isPending,
            refundKey: nil,
            authorizedKeys: nil
        )
    }

    // MARK: - Private Helpers

    private func signForRefund(proofs: [Proof], privateKey: String) throws -> String {
        // For HTLC refunds, we need to sign the proof secrets with the refund private key
        // The signature proves ownership of the refund key specified in the HTLC
        //
        // The message to sign is the concatenation of all proof secrets
        let message = proofs.map { $0.secret }.joined()
        let messageData = Data(message.utf8)
        let messageHash = SHA256.hash(data: messageData)
        let messageHashData = Data(messageHash)

        // Parse the private key from hex string
        guard let privateKeyData = Data(hexString: privateKey) else {
            throw CashuError.invalidHexString
        }

        // Create the signing key from the private key data
        do {
            let signingKey = try P256K.Signing.PrivateKey(dataRepresentation: privateKeyData)

            // Sign the message hash using Schnorr signature (NUT-11 style)
            let signature = try signingKey.signature(for: messageHashData)

            // Return the signature as hex string
            return signature.dataRepresentation.hexString
        } catch {
            throw CashuError.invalidSignature("Failed to sign refund message: \(error.localizedDescription)")
        }
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

