import Foundation

/// Protocol for secure storage operations in Cashu wallet
/// Implementations can use Keychain (Apple), file system (Linux), or in-memory storage
public protocol SecureStore: Sendable {
    
    // MARK: - Mnemonic Operations
    
    /// Save a BIP39 mnemonic phrase securely
    /// - Parameter mnemonic: The mnemonic phrase to store
    /// - Throws: An error if the storage operation fails
    func saveMnemonic(_ mnemonic: String) async throws
    
    /// Load the stored mnemonic phrase
    /// - Returns: The stored mnemonic phrase, or nil if none exists
    /// - Throws: An error if the retrieval operation fails
    func loadMnemonic() async throws -> String?
    
    /// Delete the stored mnemonic phrase
    /// - Throws: An error if the deletion operation fails
    func deleteMnemonic() async throws
    
    // MARK: - Seed Operations
    
    /// Save a seed derived from the mnemonic
    /// - Parameter seed: The seed data as a hex string
    /// - Throws: An error if the storage operation fails
    func saveSeed(_ seed: String) async throws
    
    /// Load the stored seed
    /// - Returns: The stored seed as a hex string, or nil if none exists
    /// - Throws: An error if the retrieval operation fails
    func loadSeed() async throws -> String?
    
    /// Delete the stored seed
    /// - Throws: An error if the deletion operation fails
    func deleteSeed() async throws
    
    // MARK: - Access Token Operations (NUT-21)
    
    /// Save an access token for a specific mint
    /// - Parameters:
    ///   - token: The access token to store
    ///   - mintURL: The URL of the mint this token is for
    /// - Throws: An error if the storage operation fails
    func saveAccessToken(_ token: String, mintURL: URL) async throws
    
    /// Load an access token for a specific mint
    /// - Parameter mintURL: The URL of the mint to get the token for
    /// - Returns: The stored access token, or nil if none exists
    /// - Throws: An error if the retrieval operation fails
    func loadAccessToken(mintURL: URL) async throws -> String?
    
    /// Delete an access token for a specific mint
    /// - Parameter mintURL: The URL of the mint to delete the token for
    /// - Throws: An error if the deletion operation fails
    func deleteAccessToken(mintURL: URL) async throws
    
    // MARK: - Access Token List Operations (NUT-22)
    
    /// Save a list of access tokens for a specific mint
    /// - Parameters:
    ///   - tokens: The list of access tokens to store
    ///   - mintURL: The URL of the mint these tokens are for
    /// - Throws: An error if the storage operation fails
    func saveAccessTokenList(_ tokens: [String], mintURL: URL) async throws
    
    /// Load the list of access tokens for a specific mint
    /// - Parameter mintURL: The URL of the mint to get tokens for
    /// - Returns: The stored access token list, or nil if none exists
    /// - Throws: An error if the retrieval operation fails
    func loadAccessTokenList(mintURL: URL) async throws -> [String]?
    
    /// Delete the access token list for a specific mint
    /// - Parameter mintURL: The URL of the mint to delete tokens for
    /// - Throws: An error if the deletion operation fails
    func deleteAccessTokenList(mintURL: URL) async throws
    
    // MARK: - Utility Operations
    
    /// Clear all stored data
    /// - Throws: An error if the clear operation fails
    func clearAll() async throws
    
    /// Check if the store has any data
    /// - Returns: true if the store contains any data, false otherwise
    func hasStoredData() async throws -> Bool
}

// MARK: - Optional Methods with Default Implementations

public extension SecureStore {
    /// Default implementation that clears all known data types
    func clearAll() async throws {
        try await deleteMnemonic()
        try await deleteSeed()
        // Note: Access tokens would need to be tracked separately
        // as we don't know all mint URLs
    }
    
    /// Default implementation checks for mnemonic or seed
    func hasStoredData() async throws -> Bool {
        let hasMnemonic = try await loadMnemonic() != nil
        let hasSeed = try await loadSeed() != nil
        return hasMnemonic || hasSeed
    }
}

// MARK: - SecureStore Errors

public enum SecureStoreError: LocalizedError {
    case storeFailed(String)
    case retrievalFailed(String)
    case deletionFailed(String)
    case notImplemented
    case invalidData
    
    public var errorDescription: String? {
        switch self {
        case .storeFailed(let reason):
            return "Failed to store data: \(reason)"
        case .retrievalFailed(let reason):
            return "Failed to retrieve data: \(reason)"
        case .deletionFailed(let reason):
            return "Failed to delete data: \(reason)"
        case .notImplemented:
            return "This secure store operation is not implemented"
        case .invalidData:
            return "The data format is invalid"
        }
    }
}