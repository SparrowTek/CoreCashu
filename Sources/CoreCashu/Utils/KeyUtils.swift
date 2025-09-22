//
//  KeyUtils.swift
//  CashuKit
//
//  Key management utilities for CashuKit
//

import Foundation
import P256K

// MARK: - Key Management Utilities

/// Utility functions for Cashu key management
public struct CashuKeyUtils {
    /// Generate a random 32-byte secret as hex string (recommended format)
    public static func generateRandomSecret() throws -> String {
        return try SecureRandom.generateKey().hexString
    }
    
    /// Generate a new mint keypair
    public static func generateMintKeypair() throws -> MintKeypair {
        return try MintKeypair()
    }
    
    /// Convert private key to hex string for storage
    public static func privateKeyToHex(_ privateKey: P256K.KeyAgreement.PrivateKey) -> String {
        return privateKey.rawRepresentation.hexString
    }
    
    /// Load private key from hex string
    public static func privateKeyFromHex(_ hexString: String) throws -> P256K.KeyAgreement.PrivateKey {
        guard let data = Data(hexString: hexString) else {
            throw CashuError.invalidHexString
        }
        return try P256K.KeyAgreement.PrivateKey(dataRepresentation: data)
    }
    
    /// Validate that a secret can be hashed to a valid curve point
    public static func validateSecret(_ secret: String) throws -> Bool {
        do {
            try hashToCurve(secret)
            return true
        } catch {
            return false
        }
    }
} 
