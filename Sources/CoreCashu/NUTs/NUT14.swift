//
//  NUT14.swift
//  CashuKit
//
//  NUT-14: Hashed Timelock Contracts (HTLCs)
//

import Foundation
import P256K

// MARK: - HTLC Types

/// Witness format for HTLC spending conditions
public struct HTLCWitness: Codable, Sendable {
    /// Preimage that hashes to the lock in Secret.data
    public let preimage: String
    
    /// Signatures from authorized keys
    public let signatures: [String]
    
    public init(preimage: String, signatures: [String]) {
        self.preimage = preimage
        self.signatures = signatures
    }
}

// MARK: - HTLC Secret Extensions

extension WellKnownSecret {
    /// Check if this secret is an HTLC type
    public var isHTLC: Bool {
        return kind == SpendingConditionKind.htlc
    }
    
    /// Get the hash lock from an HTLC secret
    public var hashLock: String? {
        guard isHTLC else { return nil }
        return secretData.data
    }
    
    /// Check if the HTLC has a refund condition
    public var hasRefundCondition: Bool {
        guard isHTLC else { return false }
        return secretData.tags?.first(where: { $0.first == "refund" }) != nil
    }
    
    /// Get the refund public key if present
    public var refundPublicKey: String? {
        guard isHTLC else { return nil }
        return secretData.tags?.first(where: { $0.first == "refund" })?.dropFirst().first
    }
    
    /// Get public keys from HTLC secret
    public var pubkeys: [String]? {
        guard isHTLC else { return nil }
        return secretData.tags?.compactMap { tag in
            tag.first == "pubkeys" ? Array(tag.dropFirst()) : nil
        }.flatMap { $0 }
    }
    
    /// Get locktime from HTLC secret
    public var locktime: Int64? {
        guard isHTLC else { return nil }
        guard let locktimeStr = secretData.tags?.first(where: { $0.first == "locktime" })?.dropFirst().first else {
            return nil
        }
        return Int64(locktimeStr)
    }
}

// MARK: - HTLC Verification

public struct HTLCVerifier: Sendable {
    
    /// Verify an HTLC proof
    /// - Parameters:
    ///   - proof: The proof to verify
    ///   - witness: The witness data
    ///   - currentTime: Current timestamp for locktime verification
    /// - Returns: True if the proof is valid
    public static func verifyHTLC(
        proof: Proof,
        witness: HTLCWitness,
        currentTime: Int64 = Int64(Date().timeIntervalSince1970)
    ) throws -> Bool {
        guard let secret = try? WellKnownSecret.fromString(proof.secret),
              secret.isHTLC else {
            throw CashuError.invalidSecret
        }

        // NUT-14 inherits NUT-11: every signature commits to the FULL serialized secret
        // string (the value in `proof.secret`), which binds the hash lock, pubkeys, and
        // locktime. Signing only the nonce would let a witness be replayed across
        // conditions — and no spec-compliant mint would accept it.
        let signedMessage = proof.secret

        // A malformed or absent preimage is simply "preimage not satisfied" — the refund
        // branch must still be reachable (refund witnesses carry an empty preimage).
        let preimageVerified = verifyPreimage(
            preimage: witness.preimage,
            hashLock: secret.hashLock ?? ""
        )

        // If preimage verification fails, check refund conditions
        if !preimageVerified {
            // NUT-11 semantics: with no locktime the secret is permanently locked to the
            // primary condition — the refund key never becomes spendable.
            guard let locktime = secret.locktime else {
                return false
            }
            guard currentTime >= locktime else {
                throw CashuError.locktimeNotExpired
            }

            // Verify refund signature after locktime expiry
            if let refundKey = secret.refundPublicKey {
                return verifyRefundSignature(
                    message: signedMessage,
                    witness: witness,
                    refundKey: refundKey
                )
            }

            return false
        }

        // Verify signatures for authorized public keys
        guard let pubkeys = secret.pubkeys, !pubkeys.isEmpty else {
            // If no pubkeys specified, preimage alone is sufficient
            return preimageVerified
        }

        return verifySignatures(
            message: signedMessage,
            witness: witness,
            pubkeys: pubkeys,
            requiredSigs: requiredSignatureCount(for: secret)
        )
    }

    /// The `n_sigs` threshold: k-of-n distinct signers, defaulting to 1 and never below 1.
    private static func requiredSignatureCount(for secret: WellKnownSecret) -> Int {
        guard let tag = secret.secretData.tags?.first(where: { $0.first == "n_sigs" }),
              tag.count > 1,
              let value = Int(tag[1]) else {
            return 1
        }
        return max(value, 1)
    }

    /// Verify the preimage matches the hash lock. Malformed input is a failed match, not
    /// an error — callers fall through to the refund branch.
    static func verifyPreimage(preimage: String, hashLock: String) -> Bool {
        guard let preimageData = Data(hexString: preimage),
              preimageData.count == 32 else {
            return false
        }

        let computedHash = Hash.sha256(preimageData)

        // Compare using constant-time comparison for defense in depth
        guard let lockData = Data(hexString: hashLock.lowercased()) else {
            return false
        }

        return SecureMemory.constantTimeCompare(computedHash, lockData)
    }

    /// Verify that at least `requiredSigs` distinct authorized keys signed the secret.
    /// Signature/pubkey pairing is by validity, not by array position (NUT-11 k-of-n).
    private static func verifySignatures(
        message: String,
        witness: HTLCWitness,
        pubkeys: [String],
        requiredSigs: Int
    ) -> Bool {
        var creditedSigners = Set<String>()
        var consumedSignatures = Set<Int>()

        for pubkey in pubkeys where !creditedSigners.contains(pubkey) {
            for (index, signature) in witness.signatures.enumerated() where !consumedSignatures.contains(index) {
                if P2PKSignatureValidator.validateSignature(
                    signature: signature,
                    publicKey: pubkey,
                    message: message
                ) {
                    creditedSigners.insert(pubkey)
                    consumedSignatures.insert(index)
                    break
                }
            }
        }

        return creditedSigners.count >= requiredSigs
    }

    /// Verify refund signature
    private static func verifyRefundSignature(
        message: String,
        witness: HTLCWitness,
        refundKey: String
    ) -> Bool {
        // For refund, we need at least one valid signature from the refund key
        for signature in witness.signatures {
            let verified = P2PKSignatureValidator.validateSignature(
                signature: signature,
                publicKey: refundKey,
                message: message
            )

            if verified {
                return true
            }
        }

        return false
    }
}

// MARK: - HTLC Witness Helper

extension HTLCWitness {
    /// Create witness for spending with preimage only
    public static func createForPreimage(_ preimage: Data) -> HTLCWitness {
        return HTLCWitness(
            preimage: preimage.hexString,
            signatures: []
        )
    }
    
    /// Create witness for spending with preimage and signatures using BIP340 Schnorr
    /// - Parameters:
    ///   - preimage: The HTLC preimage
    ///   - signatures: Array of tuples containing private key data (32 bytes) and message to sign
    /// - Returns: HTLCWitness with preimage and valid Schnorr signatures
    public static func createForPreimageAndSignatures(
        preimage: Data,
        signatures: [(privateKeyData: Data, message: String)]
    ) throws -> HTLCWitness {
        var signatureStrings: [String] = []
        
        for (privateKeyData, message) in signatures {
            let signature = try createSchnorrSignature(
                privateKeyData: privateKeyData,
                message: message
            )
            signatureStrings.append(signature)
        }
        
        return HTLCWitness(
            preimage: preimage.hexString,
            signatures: signatureStrings
        )
    }
    
    /// Create witness for refund (signatures only, no preimage) using BIP340 Schnorr
    /// - Parameter signatures: Array of tuples containing private key data (32 bytes) and message to sign
    /// - Returns: HTLCWitness with empty preimage and valid Schnorr signatures
    public static func createForRefund(
        signatures: [(privateKeyData: Data, message: String)]
    ) throws -> HTLCWitness {
        var signatureStrings: [String] = []
        
        for (privateKeyData, message) in signatures {
            let signature = try createSchnorrSignature(
                privateKeyData: privateKeyData,
                message: message
            )
            signatureStrings.append(signature)
        }
        
        // Use empty/zero preimage for refund (refund doesn't require preimage knowledge)
        let zeroPreimage = Data(repeating: 0, count: 32)
        
        return HTLCWitness(
            preimage: zeroPreimage.hexString,
            signatures: signatureStrings
        )
    }
    
    /// Create a BIP340 Schnorr signature for a message
    /// - Parameters:
    ///   - privateKeyData: 32-byte private key data
    ///   - message: Message string to sign (will be SHA256 hashed)
    /// - Returns: Hex-encoded 64-byte Schnorr signature
    private static func createSchnorrSignature(
        privateKeyData: Data,
        message: String
    ) throws -> String {
        guard privateKeyData.count == 32 else {
            throw CashuError.invalidSignature("Private key must be 32 bytes")
        }
        
        guard let messageData = message.data(using: .utf8) else {
            throw CashuError.invalidSignature("Invalid message encoding")
        }
        
        // Hash the message with SHA256 (BIP340 signs 32-byte messages)
        var messageBytes = Array(Hash.sha256(messageData))

        // Create Schnorr private key
        let schnorrPrivateKey = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKeyData)

        // Generate auxiliary randomness for BIP340 (improves side-channel resistance)
        var auxiliaryRand = try Array(SecureRandom.generateBytes(count: 32))

        // Create the Schnorr signature using the raw-bytes API (cross-platform friendly)
        let signature = try auxiliaryRand.withUnsafeMutableBytes { auxPtr -> P256K.Schnorr.SchnorrSignature in
            try schnorrPrivateKey.signature(
                message: &messageBytes,
                auxiliaryRand: auxPtr.baseAddress,
                strict: true
            )
        }
        
        return signature.dataRepresentation.hexString
    }
}

// MARK: - HTLC Creation

public struct HTLCCreator: Sendable {
    
    /// Create an HTLC secret
    /// - Parameters:
    ///   - preimage: The preimage (32 bytes)
    ///   - pubkeys: Public keys that can spend with the preimage
    ///   - locktime: Optional locktime for refund condition
    ///   - refundKey: Optional refund public key
    ///   - sigflag: Signature flag (default: SIG_ALL)
    /// - Returns: Encoded secret string
    public static func createHTLCSecret(
        preimage: Data,
        pubkeys: [String],
        locktime: Int64? = nil,
        refundKey: String? = nil,
        sigflag: SignatureFlag = .sigAll
    ) throws -> String {
        guard preimage.count == 32 else {
            throw CashuError.invalidPreimage
        }
        
        // Generate nonce
        let nonce = try generateNonce()
        
        // Calculate hash lock
        let hashLockHex = Hash.sha256(preimage).hexString
        
        // Build tags
        var tags: [[String]] = []
        
        // Add pubkeys
        if !pubkeys.isEmpty {
            tags.append(["pubkeys"] + pubkeys)
        }
        
        // Add locktime if specified
        if let locktime = locktime {
            tags.append(["locktime", String(locktime)])
        }
        
        // Add refund key if specified
        if let refundKey = refundKey {
            tags.append(["refund", refundKey])
        }
        
        // NUT-11: an absent sigflag tag means SIG_INPUTS, so SIG_ALL must always be
        // written explicitly — omitting it silently weakened the lock to SIG_INPUTS.
        if sigflag != .sigInputs {
            tags.append(["sigflag", sigflag.rawValue])
        }
        
        // Create secret
        let secretData = WellKnownSecret.SecretData(
            nonce: nonce,
            data: hashLockHex,
            tags: tags.isEmpty ? nil : tags
        )
        
        let secret = WellKnownSecret(
            kind: SpendingConditionKind.htlc,
            secretData: secretData
        )
        
        return try secret.toJSONString()
    }
    
    /// Generate a random 32-byte preimage
    /// - Throws: CashuError.keyGenerationFailed if secure random generation fails
    public static func generatePreimage() throws -> Data {
        // Use cross-platform secure random generation
        // SECURITY: Never fall back to weak random - cryptographic preimages must be secure
        return try SecureRandom.generateKey()
    }
    
    private static func generateNonce() throws -> String {
        // Use cross-platform secure random generation
        // SECURITY: Never fall back to weak random - cryptographic nonces must be secure
        let nonce = try SecureRandom.generateNonce()
        return nonce.hexString
    }
}

// MARK: - HTLC Helper Functions

/// Helper functions for HTLC operations
public struct HTLCHelper: Sendable {
    
    /// Create an HTLC-locked secret that can be used in proof creation
    /// - Parameters:
    ///   - preimage: The preimage for the HTLC
    ///   - pubkeys: Public keys that can spend with the preimage
    ///   - locktime: Optional locktime for refund
    ///   - refundKey: Optional refund public key
    /// - Returns: HTLC secret string
    public static func createHTLCSecret(
        preimage: Data,
        pubkeys: [String],
        locktime: Int64? = nil,
        refundKey: String? = nil
    ) throws -> String {
        return try HTLCCreator.createHTLCSecret(
            preimage: preimage,
            pubkeys: pubkeys,
            locktime: locktime,
            refundKey: refundKey
        )
    }
    
    /// Verify HTLC proofs can be spent with given witness
    /// - Parameters:
    ///   - proofs: HTLC-locked proofs to verify
    ///   - witness: HTLC witness with preimage and signatures
    /// - Returns: True if all proofs can be spent with the witness
    public static func verifyHTLCProofs(
        proofs: [Proof],
        witness: HTLCWitness
    ) throws -> Bool {
        // Verify all proofs are HTLC type and can be spent with witness
        for proof in proofs {
            guard let secret = try? WellKnownSecret.fromString(proof.secret),
                  secret.isHTLC else {
                throw CashuError.invalidProofType
            }
            
            // Verify the witness is valid for this proof
            let isValid = try HTLCVerifier.verifyHTLC(
                proof: proof,
                witness: witness
            )
            
            if !isValid {
                return false
            }
        }
        
        return true
    }
    
    /// Attach witness data to proofs for spending
    /// - Parameters:
    ///   - proofs: HTLC-locked proofs
    ///   - witness: HTLC witness data
    /// - Returns: Proofs with witness attached
    public static func attachWitnessToProofs(
        proofs: [Proof],
        witness: HTLCWitness
    ) throws -> [Proof] {
        // Create witness JSON
        let witnessData = try JSONEncoder().encode(witness)
        let witnessString = String(data: witnessData, encoding: .utf8) ?? ""
        
        // Create proofs with witness attached
        var witnessProofs: [Proof] = []
        for proof in proofs {
            let witnessProof = Proof(
                amount: proof.amount,
                id: proof.id,
                secret: proof.secret,
                C: proof.C,
                witness: witnessString,
                dleq: proof.dleq
            )
            witnessProofs.append(witnessProof)
        }
        
        return witnessProofs
    }
}

// MARK: - Mint Info Extensions

extension MintInfo {
    /// Check if the mint supports NUT-14 (HTLCs)
    public var supportsHTLC: Bool {
        return supportsNUT("14")
    }
    
    /// Get NUT-14 settings if supported
    public func getNUT14Settings() -> NUT14Settings? {
        guard let nut14Data = nuts?["14"]?.dictionaryValue else { return nil }
        
        let supported = nut14Data["supported"] as? Bool ?? false
        
        return NUT14Settings(supported: supported)
    }
}

/// NUT-14 settings from mint info
public struct NUT14Settings: Codable, Sendable {
    public let supported: Bool
    
    public init(supported: Bool) {
        self.supported = supported
    }
}