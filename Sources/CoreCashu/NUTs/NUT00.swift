//
//  NUT00_BlindDiffieHellmanKeyExchange.swift
//  CashuKit
//
//  NUT-00: Blind Diffie-Hellman Key Exchange
//  https://github.com/cashubtc/nuts/blob/main/00.md
//

import Foundation
@preconcurrency import P256K

/// NUT-00: Blind Diffie-Hellman Key Exchange (BDHKE)
///
/// This module implements the core cryptographic protocol for Cashu, based on
/// blind signatures using the secp256k1 elliptic curve. The BDHKE protocol
/// enables privacy-preserving token minting and verification.
///
/// ## Specification Reference
/// - Section 1: Overview - Defines BDHKE as the core protocol
/// - Section 2: Model - Alice (user) and Bob (mint) roles
/// - Section 3: Protocol - Detailed steps for blinding and signing
/// - Section 4: Blind Signatures - Mathematical operations for blinding
/// - Section 5: Blinded Messages - Hash-to-curve and point operations
///
/// ## Key Components
/// - Hash-to-curve function (hashToCurve) - Maps messages to curve points
/// - Blinding factor generation - Creates random blinding factors
/// - Blind signature verification - Validates mint signatures
///
/// ## Security Properties
/// - Unlinkability: Mint cannot link blinded messages to unblinded tokens
/// - Unforgeability: Only the mint can create valid signatures
/// - Privacy: User's messages remain hidden from the mint
// MARK: - NUT-00: Blind Diffie-Hellman Key Exchange

// MARK: - KeyAgreement PublicKey Extensions

extension P256K.KeyAgreement.PublicKey {
    /// Negates a public key by converting to Signing.PublicKey and back.
    ///
    /// `P256K.Signing.PublicKey.negation` is non-throwing in P256K 0.23+, so the only
    /// throwing operations here are the two `init(dataRepresentation:format:)` calls.
    public var negation: P256K.KeyAgreement.PublicKey {
        get throws {
            try CryptoLock.shared.withLock {
                let signingKey = try P256K.Signing.PublicKey(dataRepresentation: self.dataRepresentation, format: .compressed)
                let negatedSigningKey = signingKey.negation
                return try P256K.KeyAgreement.PublicKey(dataRepresentation: negatedSigningKey.dataRepresentation, format: .compressed)
            }
        }
    }
}

// MARK: - BDHKE Primitives Namespace
//
// Phase 8.11 (2026-04-29): Low-level Blind Diffie-Hellman Key Exchange primitives are namespaced
// under `BDHKE` to signal "advanced — you are off the supported wallet path." High-level wallet
// users should never need to call into this namespace directly. The legacy top-level functions
// (`hashToCurve`, `getGeneratorPoint`, `multiplyPoint`, `addPoints`, `subtractPoints`) remain as
// deprecated thin wrappers for one migration cycle and forward to these implementations.

/// Low-level cryptographic primitives that implement the Blind Diffie-Hellman Key Exchange.
///
/// Most consumers should use the high-level wallet API (``CashuWallet``) instead. The members
/// of this namespace are exposed for advanced consumers who need to construct or verify proofs
/// outside the wallet boundary.
public enum BDHKE {

    /// Maps a message to a public key point on the secp256k1 curve.
    ///
    /// `Y = hash_to_curve(x)` where `x` is the secret message. Implementation follows NUT-00:
    /// `Y = PublicKey('02' || SHA256(msg_hash || counter))` with the Cashu domain separator.
    public static func hashToCurve(_ message: Data) throws -> P256K.KeyAgreement.PublicKey {
        try CryptoLock.shared.withLock {
            guard let domainSeparator = "Secp256k1_HashToCurve_Cashu_".data(using: .utf8) else {
                throw CashuError.domainSeperator
            }

            let msgHash = Hash.sha256(domainSeparator + message)

            for counter in 0..<UInt32.max {
                let counterBytes = withUnsafeBytes(of: counter.littleEndian) { Data($0) }
                let candidate = Hash.sha256(msgHash + counterBytes)
                let candidateWithPrefix = Data([0x02]) + candidate

                do {
                    return try P256K.KeyAgreement.PublicKey(dataRepresentation: candidateWithPrefix, format: .compressed)
                } catch {
                    continue
                }
            }

            throw CashuError.hashToCurveFailed
        }
    }

    /// Convenience overload accepting a UTF-8 string. Throws if the string is not UTF-8 representable.
    @discardableResult
    public static func hashToCurve(_ message: String) throws -> P256K.KeyAgreement.PublicKey {
        guard let data = message.data(using: .utf8) else {
            throw CashuError.invalidSecretLength
        }
        return try hashToCurve(data)
    }

    /// Returns the secp256k1 generator point `G`.
    public static func generatorPoint() throws -> P256K.KeyAgreement.PublicKey {
        try CryptoLock.shared.withLock {
            let oneData = Data([
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01
            ])

            let privateKeyOne = try P256K.KeyAgreement.PrivateKey(dataRepresentation: oneData)
            return privateKeyOne.publicKey
        }
    }

    /// Multiplies a point by a scalar (private key): `scalar * point`.
    public static func multiply(
        point: P256K.KeyAgreement.PublicKey,
        scalar: P256K.KeyAgreement.PrivateKey
    ) throws -> P256K.KeyAgreement.PublicKey {
        try CryptoLock.shared.withLock {
            let signingPoint = try P256K.Signing.PublicKey(dataRepresentation: point.dataRepresentation, format: .compressed)
            let signingScalar = try P256K.Signing.PrivateKey(dataRepresentation: scalar.rawRepresentation)
            let resultSigningPoint = try signingPoint.multiply(signingScalar.dataRepresentation.bytes, format: .compressed)
            return try P256K.KeyAgreement.PublicKey(dataRepresentation: resultSigningPoint.dataRepresentation, format: .compressed)
        }
    }

    /// Adds two points on the secp256k1 curve.
    public static func add(
        _ point1: P256K.KeyAgreement.PublicKey,
        _ point2: P256K.KeyAgreement.PublicKey
    ) throws -> P256K.KeyAgreement.PublicKey {
        try CryptoLock.shared.withLock {
            let signingPoint1 = try P256K.Signing.PublicKey(dataRepresentation: point1.dataRepresentation, format: .compressed)
            let signingPoint2 = try P256K.Signing.PublicKey(dataRepresentation: point2.dataRepresentation, format: .compressed)
            let resultSigningPoint = try signingPoint1.combine([signingPoint2], format: .compressed)
            return try P256K.KeyAgreement.PublicKey(dataRepresentation: resultSigningPoint.dataRepresentation, format: .compressed)
        }
    }

    /// Subtracts the second point from the first on the secp256k1 curve.
    public static func subtract(
        _ point1: P256K.KeyAgreement.PublicKey,
        _ point2: P256K.KeyAgreement.PublicKey
    ) throws -> P256K.KeyAgreement.PublicKey {
        let negatedPoint2 = try point2.negation
        return try add(point1, negatedPoint2)
    }
}

// MARK: - Deprecated top-level aliases (Phase 8.11 migration window)

@available(*, deprecated, renamed: "BDHKE.hashToCurve(_:)", message: "Low-level BDHKE primitives moved under the BDHKE namespace in Phase 8.11. Use BDHKE.hashToCurve(_:) instead.")
public func hashToCurve(_ message: Data) throws -> P256K.KeyAgreement.PublicKey {
    try BDHKE.hashToCurve(message)
}

@available(*, deprecated, renamed: "BDHKE.hashToCurve(_:)", message: "Low-level BDHKE primitives moved under the BDHKE namespace in Phase 8.11. Use BDHKE.hashToCurve(_:) instead.")
@discardableResult
public func hashToCurve(_ message: String) throws -> P256K.KeyAgreement.PublicKey {
    try BDHKE.hashToCurve(message)
}

@available(*, deprecated, renamed: "BDHKE.generatorPoint()", message: "Low-level BDHKE primitives moved under the BDHKE namespace in Phase 8.11. Use BDHKE.generatorPoint() instead.")
public func getGeneratorPoint() throws -> P256K.KeyAgreement.PublicKey {
    try BDHKE.generatorPoint()
}

@available(*, deprecated, renamed: "BDHKE.multiply(point:scalar:)", message: "Low-level BDHKE primitives moved under the BDHKE namespace in Phase 8.11. Use BDHKE.multiply(point:scalar:) instead.")
public func multiplyPoint(_ point: P256K.KeyAgreement.PublicKey, by scalar: P256K.KeyAgreement.PrivateKey) throws -> P256K.KeyAgreement.PublicKey {
    try BDHKE.multiply(point: point, scalar: scalar)
}

@available(*, deprecated, renamed: "BDHKE.add(_:_:)", message: "Low-level BDHKE primitives moved under the BDHKE namespace in Phase 8.11. Use BDHKE.add(_:_:) instead.")
public func addPoints(_ point1: P256K.KeyAgreement.PublicKey, _ point2: P256K.KeyAgreement.PublicKey) throws -> P256K.KeyAgreement.PublicKey {
    try BDHKE.add(point1, point2)
}

@available(*, deprecated, renamed: "BDHKE.subtract(_:_:)", message: "Low-level BDHKE primitives moved under the BDHKE namespace in Phase 8.11. Use BDHKE.subtract(_:_:) instead.")
public func subtractPoints(_ point1: P256K.KeyAgreement.PublicKey, _ point2: P256K.KeyAgreement.PublicKey) throws -> P256K.KeyAgreement.PublicKey {
    try BDHKE.subtract(point1, point2)
}

// MARK: - Mint Implementation

/// Represents a mint's cryptographic keys for one amount
/// Each amount has its own key pair in Cashu
public struct MintKeypair {
    /// k: private key of mint (one for each amount)
    public let privateKey: P256K.KeyAgreement.PrivateKey
    /// K: public key corresponding to k (K = k*G)
    public let publicKey: P256K.KeyAgreement.PublicKey

    public init() throws {
        (self.privateKey, self.publicKey) = try CryptoLock.shared.withLock {
            let pk = try P256K.KeyAgreement.PrivateKey()
            return (pk, pk.publicKey)
        }
    }

    public init(privateKey: P256K.KeyAgreement.PrivateKey) {
        self.privateKey = privateKey
        self.publicKey = CryptoLock.shared.withLock {
            privateKey.publicKey
        }
    }
}

/// Mint operations in the BDHKE protocol
public struct Mint {
    public let keypair: MintKeypair
    
    public init() throws {
        self.keypair = try MintKeypair()
    }
    
    public init(privateKey: P256K.KeyAgreement.PrivateKey) {
        self.keypair = MintKeypair(privateKey: privateKey)
    }
    
    /// Step 2 of BDHKE: Mint signs the blinded message
    /// Input: B_ (blinded message from wallet)
    /// Output: C_ = k * B_ (blinded signature)
    public func signBlindedMessage(_ blindedMessage: Data) throws -> Data {
        // Parse B_ as a compressed public key
        let blindedMessagePublicKey = try P256K.KeyAgreement.PublicKey(dataRepresentation: blindedMessage, format: .compressed)
        
        // Sign: C_ = k * B_
        let blindedSignature = try BDHKE.multiply(point: blindedMessagePublicKey, scalar: keypair.privateKey)
        
        // Return C_ as compressed public key data
        return blindedSignature.dataRepresentation
    }
    
    /// Step 4 of BDHKE: Verify an unblinded signature
    /// Check that k * hash_to_curve(x) == C
    /// This is how the mint verifies a token is valid when it's spent
    public func verifyToken(secret: String, signature: Data) throws -> Bool {
        // Parse the signature as a compressed public key
        let signaturePublicKey = try P256K.KeyAgreement.PublicKey(dataRepresentation: signature, format: .compressed)
        
        // Compute k * hash_to_curve(x)
        let secretPoint = try BDHKE.hashToCurve(secret)
        let expectedSignature = try BDHKE.multiply(point: secretPoint, scalar: keypair.privateKey)
        
        // Compare the points using constant-time comparison to prevent timing attacks
        return SecureMemory.constantTimeCompare(
            signaturePublicKey.dataRepresentation,
            expectedSignature.dataRepresentation
        )
    }
}

// MARK: - Wallet Implementation

/// Represents wallet's blinding data for one token
public struct WalletBlindingData: Sendable {
    /// x: UTF-8-encoded secret message
    public let secret: String
    /// r: blinding factor (private key)
    public let blindingFactor: P256K.KeyAgreement.PrivateKey
    /// Y: hash_to_curve(x)
    public let secretPoint: P256K.KeyAgreement.PublicKey
    /// B_: blinded message (Y + r*G)
    public let blindedMessage: P256K.KeyAgreement.PublicKey
    
    public init(secret: String) throws {
        self.secret = secret
        self.blindingFactor = try P256K.KeyAgreement.PrivateKey()
        self.secretPoint = try BDHKE.hashToCurve(secret)

        // Create blinded message: B_ = Y + r*G
        let generatorPoint = try BDHKE.generatorPoint()
        let rG = try BDHKE.multiply(point: generatorPoint, scalar: self.blindingFactor)
        self.blindedMessage = try BDHKE.add(self.secretPoint, rG)
    }

    /// Construct blinding data from a caller-supplied (secret, blinding factor) pair.
    /// Used by NUT-13 deterministic derivation so mint/swap outputs can be reproduced from the
    /// seed (Phase 8.10/8.3 — restore-from-seed actually works after this lands).
    public init(secret: String, blindingFactor: Data) throws {
        self.secret = secret
        self.blindingFactor = try P256K.KeyAgreement.PrivateKey(dataRepresentation: blindingFactor)
        self.secretPoint = try BDHKE.hashToCurve(secret)
        let generatorPoint = try BDHKE.generatorPoint()
        let rG = try BDHKE.multiply(point: generatorPoint, scalar: self.blindingFactor)
        self.blindedMessage = try BDHKE.add(self.secretPoint, rG)
    }
}

/// Represents an unblinded token
public struct UnblindedToken {
    /// x: the original secret
    public let secret: String
    /// C: unblinded signature
    public let signature: Data
    
    public init(secret: String, signature: Data) {
        self.secret = secret
        self.signature = signature
    }
}

/// Wallet operations in the BDHKE protocol
public struct Wallet {
    
    /// Step 1 of BDHKE: Create a blinded message for the mint to sign
    /// Input: x (secret)
    /// Output: B_ = Y + r*G where Y = hash_to_curve(x) and r is random
    public static func createBlindedMessage(secret: String) throws -> (blindingData: WalletBlindingData, blindedMessage: Data) {
        let blindingData = try WalletBlindingData(secret: secret)
        
        // Convert B_ to compressed public key format for transmission
        let blindedMessage = blindingData.blindedMessage.dataRepresentation
        
        return (blindingData, blindedMessage)
    }
    
    /// Step 3 of BDHKE: Unblind the signature received from the mint
    /// Input: C_ (blinded signature), blinding data, K (mint public key)
    /// Output: C = C_ - r*K (unblinded signature)
    public static func unblindSignature(
        blindedSignature: Data,
        blindingData: WalletBlindingData,
        mintPublicKey: P256K.KeyAgreement.PublicKey
    ) throws -> UnblindedToken {
        // Parse C_ as a compressed public key
        let blindedSigPublicKey = try P256K.KeyAgreement.PublicKey(dataRepresentation: blindedSignature, format: .compressed)
        
        // Unblind: C = C_ - r*K
        let rK = try BDHKE.multiply(point: mintPublicKey, scalar: blindingData.blindingFactor)
        let unblindedSignaturePoint = try BDHKE.subtract(blindedSigPublicKey, rK)
        
        // Convert to data for storage/transmission
        let signatureData = unblindedSignaturePoint.dataRepresentation
        
        return UnblindedToken(secret: blindingData.secret, signature: signatureData)
    }
    
    /// Verify a token's mathematical validity (without the mint's private key)
    /// Note: This only validates the token structure, not whether it's actually valid
    /// For actual verification, the token must be sent to the mint
    public static func validateTokenStructure(_ token: UnblindedToken) -> Bool {
        // Basic validation - check that signature is a valid compressed public key
        guard let signatureData = Data(hexString: token.signature.hexString),
              signatureData.count == 33,
              signatureData.first == 0x02 || signatureData.first == 0x03 else {
            return false
        }
        
        // Check that secret is not empty
        guard !token.secret.isEmpty else {
            return false
        }
        
        // Try to parse signature as a valid public key
        do {
            _ = try P256K.KeyAgreement.PublicKey(dataRepresentation: signatureData, format: .compressed)
            return true
        } catch {
            return false
        }
    }
    
    /// Verify a token locally using mint's public key
    /// This simulates what the mint would do: check k*hash_to_curve(x) == C
    /// WARNING: This requires knowing the mint's private key, which wallets don't have
    public static func verifyTokenWithMintKey(_ token: UnblindedToken, mintPrivateKey: P256K.KeyAgreement.PrivateKey) throws -> Bool {
        let mint = Mint(privateKey: mintPrivateKey)
        return try mint.verifyToken(secret: token.secret, signature: token.signature)
    }
}

// MARK: - Protocol Flow Implementation

/// Complete BDHKE protocol flow following NUT-00
public struct CashuBDHKEProtocol {
    
    /// Execute the complete BDHKE protocol
    /// This demonstrates the full flow from NUT-00
    public static func executeProtocol(secret: String) throws -> (token: UnblindedToken, isValid: Bool) {
        // Setup: Mint publishes public key K = k*G
        let mint = try Mint()
        let mintPublicKey = mint.keypair.publicKey
        
        // Step 1: Wallet picks secret x and computes Y = hash_to_curve(x)
        //         Wallet sends B_ = Y + r*G to mint (blinding)
        let (blindingData, blindedMessage) = try Wallet.createBlindedMessage(secret: secret)
        
        // Step 2: Mint signs the blinded message and sends back C_ = k*B_ (signing)
        let blindedSignature = try mint.signBlindedMessage(blindedMessage)
        
        // Step 3: Wallet unblinds the signature: C = C_ - r*K (unblinding)
        let token = try Wallet.unblindSignature(
            blindedSignature: blindedSignature,
            blindingData: blindingData,
            mintPublicKey: mintPublicKey
        )
        
        // Step 4: Verification - Mint checks k*hash_to_curve(x) == C
        let isValid = try mint.verifyToken(secret: token.secret, signature: token.signature)
        
        return (token, isValid)
    }
} 
