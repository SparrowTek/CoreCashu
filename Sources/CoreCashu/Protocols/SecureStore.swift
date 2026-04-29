import Foundation

/// Protocol for secure storage operations in Cashu wallet
/// Implementations can use Keychain (Apple), file system (Linux), or in-memory storage.
///
/// Phase 8.10 (2026-04-29) — completed in the Phase 8 follow-up window. Mnemonic operations now
/// take ``SensitiveString`` as their canonical type so the plaintext lifetime is bounded by the
/// wrapper's deinit (zero-on-drop). The legacy ``String``-based overloads live in an extension
/// for migration ergonomics; conformers only implement the ``SensitiveString`` versions.
public protocol SecureStore: Sendable {

    // MARK: - Mnemonic Operations

    /// Save a BIP39 mnemonic phrase securely.
    /// - Parameter mnemonic: The mnemonic phrase to store, wrapped in `SensitiveString` so its
    ///   plaintext is zeroed when the wrapper is released.
    func saveMnemonic(_ mnemonic: SensitiveString) async throws

    /// Load the stored mnemonic phrase.
    /// - Returns: The stored mnemonic wrapped in `SensitiveString`, or `nil` if none exists.
    func loadMnemonic() async throws -> SensitiveString?

    /// Delete the stored mnemonic phrase.
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

    // MARK: - String-based mnemonic conveniences (Phase 8.10)
    //
    // Forward to the canonical `SensitiveString` requirements. New code should prefer the
    // `SensitiveString` overloads directly so the plaintext lifetime is bounded by the wrapper.

    /// Save a BIP39 mnemonic from a `String`. Wraps the input in `SensitiveString` immediately
    /// so the plaintext lifetime is bounded by the wrapper's deinit.
    func saveMnemonic(_ mnemonic: String) async throws {
        try await saveMnemonic(SensitiveString(mnemonic))
    }

    /// Load the stored mnemonic and copy it out as a `String` for compatibility with code
    /// paths that haven't migrated to `SensitiveString` yet.
    ///
    /// **Prefer `loadMnemonic() async throws -> SensitiveString?`** in new code — the
    /// `SensitiveString` form keeps the plaintext under the wrapper's lock and wipes on deinit.
    func loadMnemonicString() async throws -> String? {
        guard let sensitive = try await loadMnemonic() else { return nil }
        return sensitive.withString { plaintext in String(plaintext) }
    }
}

// MARK: - SecureStore Errors

public enum SecureStoreError: LocalizedError {
    case storeFailed(String)
    case retrievalFailed(String)
    case deletionFailed(String)
    case notImplemented
    case invalidData
    /// Thrown by `FileSecureStore` when constructed without a password and without explicit
    /// opt-in to the unprotected ephemeral mode. The default fails closed: callers must pass
    /// a non-empty `password` (PBKDF2-derived AES key) or set
    /// `Configuration.allowEphemeralUnprotectedKey = true` after acknowledging the threat
    /// model in `Docs/security_assumptions.md`.
    case passwordRequired

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
        case .passwordRequired:
            return "FileSecureStore requires a password (or opt-in unprotected mode)"
        }
    }
}