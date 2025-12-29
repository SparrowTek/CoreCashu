//
//  CashuWallet+Token.swift
//  CoreCashu
//
//  Token import/export operations for CashuWallet
//

import Foundation

// MARK: - Token Import/Export

public extension CashuWallet {
    
    /// Import a token from a serialized string
    /// - Parameter serializedToken: The serialized token string
    /// - Returns: Array of imported proofs
    func importToken(_ serializedToken: String) async throws -> [Proof] {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        
        // Deserialize the token
        let token = try CashuTokenUtils.deserializeToken(serializedToken)
        
        // Validate the token
        let validationResult = ValidationUtils.validateCashuToken(token)
        guard validationResult.isValid else {
            throw CashuError.invalidTokenStructure
        }
        
        // Receive the token (this will add proofs to our storage)
        return try await receive(token: token)
    }
    
    /// Export a token with specified amount
    /// - Parameters:
    ///   - amount: Amount to export
    ///   - memo: Optional memo for the token
    ///   - version: Token version (defaults to V3)
    ///   - includeURI: Whether to include the URI scheme
    /// - Returns: Serialized token string
    func exportToken(
        amount: Int,
        memo: String? = nil,
        version: TokenVersion = .v3,
        includeURI: Bool = false
    ) async throws -> String {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        
        // Create the token
        let token = try await send(amount: amount, memo: memo)
        
        // Serialize the token
        return try CashuTokenUtils.serializeToken(token, version: version, includeURI: includeURI)
    }
    
    /// Export all available tokens
    /// - Parameters:
    ///   - memo: Optional memo for the token
    ///   - version: Token version (defaults to V3)
    ///   - includeURI: Whether to include the URI scheme
    /// - Returns: Serialized token string
    func exportAllTokens(
        memo: String? = nil,
        version: TokenVersion = .v3,
        includeURI: Bool = false
    ) async throws -> String {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        
        let totalBalance = try await balance
        guard totalBalance > 0 else {
            throw CashuError.balanceInsufficient
        }
        
        return try await exportToken(
            amount: totalBalance,
            memo: memo,
            version: version,
            includeURI: includeURI
        )
    }
    
    /// Create a token from existing proofs
    /// - Parameters:
    ///   - proofs: Proofs to include in the token
    ///   - memo: Optional memo for the token
    /// - Returns: CashuToken containing the proofs
    func createToken(from proofs: [Proof], memo: String? = nil) async throws -> CashuToken {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        
        guard !proofs.isEmpty else {
            throw CashuError.noSpendableProofs
        }
        
        // Validate proofs
        let validationResult = ValidationUtils.validateProofs(proofs)
        guard validationResult.isValid else {
            throw CashuError.invalidProofSet
        }
        
        let tokenEntry = TokenEntry(
            mint: configuration.mintURL,
            proofs: proofs
        )
        
        return CashuToken(
            token: [tokenEntry],
            unit: configuration.unit,
            memo: memo
        )
    }
}
