import Foundation

/// In-memory implementation of SecureStore for testing and non-persistent storage
/// WARNING: This implementation stores sensitive data in memory and is NOT secure for production use
public actor InMemorySecureStore: SecureStore {
    
    private var storage: [String: String] = [:]
    
    // Storage keys
    private let mnemonicKey = "cashu.mnemonic"
    private let seedKey = "cashu.seed"
    private let accessTokenPrefix = "cashu.accessToken."
    private let accessTokenListPrefix = "cashu.accessTokenList."
    
    public init() {}
    
    // MARK: - Mnemonic Operations
    
    public func saveMnemonic(_ mnemonic: String) async throws {
        storage[mnemonicKey] = mnemonic
    }
    
    public func loadMnemonic() async throws -> String? {
        storage[mnemonicKey]
    }
    
    public func deleteMnemonic() async throws {
        storage.removeValue(forKey: mnemonicKey)
    }
    
    // MARK: - Seed Operations
    
    public func saveSeed(_ seed: String) async throws {
        storage[seedKey] = seed
    }
    
    public func loadSeed() async throws -> String? {
        storage[seedKey]
    }
    
    public func deleteSeed() async throws {
        storage.removeValue(forKey: seedKey)
    }
    
    // MARK: - Access Token Operations
    
    public func saveAccessToken(_ token: String, mintURL: URL) async throws {
        let key = accessTokenKey(for: mintURL)
        storage[key] = token
    }
    
    public func loadAccessToken(mintURL: URL) async throws -> String? {
        let key = accessTokenKey(for: mintURL)
        return storage[key]
    }
    
    public func deleteAccessToken(mintURL: URL) async throws {
        let key = accessTokenKey(for: mintURL)
        storage.removeValue(forKey: key)
    }
    
    // MARK: - Access Token List Operations
    
    public func saveAccessTokenList(_ tokens: [String], mintURL: URL) async throws {
        let key = accessTokenListKey(for: mintURL)
        let data = try JSONEncoder().encode(tokens)
        storage[key] = String(data: data, encoding: .utf8)
    }
    
    public func loadAccessTokenList(mintURL: URL) async throws -> [String]? {
        let key = accessTokenListKey(for: mintURL)
        guard let jsonString = storage[key],
              let data = jsonString.data(using: .utf8) else {
            return nil
        }
        return try JSONDecoder().decode([String].self, from: data)
    }
    
    public func deleteAccessTokenList(mintURL: URL) async throws {
        let key = accessTokenListKey(for: mintURL)
        storage.removeValue(forKey: key)
    }
    
    // MARK: - Utility Operations
    
    public func clearAll() async throws {
        storage.removeAll()
    }
    
    public func hasStoredData() async throws -> Bool {
        !storage.isEmpty
    }
    
    // MARK: - Private Helpers
    
    private func accessTokenKey(for mintURL: URL) -> String {
        "\(accessTokenPrefix)\(mintURL.absoluteString)"
    }
    
    private func accessTokenListKey(for mintURL: URL) -> String {
        "\(accessTokenListPrefix)\(mintURL.absoluteString)"
    }
}

// MARK: - Thread-Safe Wrapper for Non-Actor Contexts

/// A thread-safe wrapper around InMemorySecureStore for use in non-actor contexts
public final class InMemorySecureStoreWrapper: SecureStore, @unchecked Sendable {
    private let store = InMemorySecureStore()
    
    public init() {}
    
    public func saveMnemonic(_ mnemonic: String) async throws {
        try await store.saveMnemonic(mnemonic)
    }
    
    public func loadMnemonic() async throws -> String? {
        try await store.loadMnemonic()
    }
    
    public func deleteMnemonic() async throws {
        try await store.deleteMnemonic()
    }
    
    public func saveSeed(_ seed: String) async throws {
        try await store.saveSeed(seed)
    }
    
    public func loadSeed() async throws -> String? {
        try await store.loadSeed()
    }
    
    public func deleteSeed() async throws {
        try await store.deleteSeed()
    }
    
    public func saveAccessToken(_ token: String, mintURL: URL) async throws {
        try await store.saveAccessToken(token, mintURL: mintURL)
    }
    
    public func loadAccessToken(mintURL: URL) async throws -> String? {
        try await store.loadAccessToken(mintURL: mintURL)
    }
    
    public func deleteAccessToken(mintURL: URL) async throws {
        try await store.deleteAccessToken(mintURL: mintURL)
    }
    
    public func saveAccessTokenList(_ tokens: [String], mintURL: URL) async throws {
        try await store.saveAccessTokenList(tokens, mintURL: mintURL)
    }
    
    public func loadAccessTokenList(mintURL: URL) async throws -> [String]? {
        try await store.loadAccessTokenList(mintURL: mintURL)
    }
    
    public func deleteAccessTokenList(mintURL: URL) async throws {
        try await store.deleteAccessTokenList(mintURL: mintURL)
    }
    
    public func clearAll() async throws {
        try await store.clearAll()
    }
    
    public func hasStoredData() async throws -> Bool {
        try await store.hasStoredData()
    }
}