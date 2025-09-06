//
//  FileSecureStore.swift
//  CoreCashu
//
//  File-based encrypted storage implementation for cross-platform use
//

import Foundation
import CryptoKit
import CryptoSwift

/// File-based secure storage for Linux and cross-platform use
public actor FileSecureStore: SecureStore {
    
    private let storageDirectory: URL
    private let encryptionKey: SymmetricKey
    
    /// File names for different types of data
    private enum FileName {
        static let mnemonic = "mnemonic.enc"
        static let seed = "seed.enc"
        static let accessTokens = "access_tokens.enc"
        static let accessTokenLists = "access_token_lists.enc"
        static let keyDerivation = "key_derivation.salt"
    }
    
    /// Initialize the file-based secure store
    /// - Parameters:
    ///   - directory: Directory to store encrypted files (default: ~/.cashu/secure)
    ///   - password: Optional password for key derivation. If nil, generates a random key stored with the data
    public init(directory: URL? = nil, password: String? = nil) async throws {
        // Set storage directory
        if let directory = directory {
            self.storageDirectory = directory
        } else {
            let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
            self.storageDirectory = homeDirectory.appendingPathComponent(".cashu/secure")
        }
        
        // Create directory if it doesn't exist
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700] // rwx------
        )
        
        // Derive or generate encryption key
        if let password = password {
            self.encryptionKey = try await FileSecureStore.deriveKey(
                from: password,
                storageDirectory: storageDirectory
            )
        } else {
            self.encryptionKey = try await FileSecureStore.generateOrLoadKey(
                storageDirectory: storageDirectory
            )
        }
    }
    
    // MARK: - Mnemonic Operations
    
    public func saveMnemonic(_ mnemonic: String) async throws {
        let url = storageDirectory.appendingPathComponent(FileName.mnemonic)
        try await saveEncrypted(mnemonic, to: url)
    }
    
    public func loadMnemonic() async throws -> String? {
        let url = storageDirectory.appendingPathComponent(FileName.mnemonic)
        return try await loadEncrypted(from: url)
    }
    
    public func deleteMnemonic() async throws {
        let url = storageDirectory.appendingPathComponent(FileName.mnemonic)
        try deleteFile(at: url)
    }
    
    // MARK: - Seed Operations
    
    public func saveSeed(_ seed: String) async throws {
        let url = storageDirectory.appendingPathComponent(FileName.seed)
        try await saveEncrypted(seed, to: url)
    }
    
    public func loadSeed() async throws -> String? {
        let url = storageDirectory.appendingPathComponent(FileName.seed)
        return try await loadEncrypted(from: url)
    }
    
    public func deleteSeed() async throws {
        let url = storageDirectory.appendingPathComponent(FileName.seed)
        try deleteFile(at: url)
    }
    
    // MARK: - Access Token Operations
    
    public func saveAccessToken(_ token: String, mintURL: URL) async throws {
        var tokens = try await loadAllAccessTokens() ?? [:]
        tokens[mintURL.absoluteString] = token
        try await saveAllAccessTokens(tokens)
    }
    
    public func loadAccessToken(mintURL: URL) async throws -> String? {
        let tokens = try await loadAllAccessTokens()
        return tokens?[mintURL.absoluteString]
    }
    
    public func deleteAccessToken(mintURL: URL) async throws {
        var tokens = try await loadAllAccessTokens() ?? [:]
        tokens.removeValue(forKey: mintURL.absoluteString)
        try await saveAllAccessTokens(tokens)
    }
    
    // MARK: - Access Token List Operations
    
    public func saveAccessTokenList(_ tokenList: [String], mintURL: URL) async throws {
        var tokenLists = try await loadAllAccessTokenLists() ?? [:]
        tokenLists[mintURL.absoluteString] = tokenList
        try await saveAllAccessTokenLists(tokenLists)
    }
    
    public func loadAccessTokenList(mintURL: URL) async throws -> [String]? {
        let tokenLists = try await loadAllAccessTokenLists()
        return tokenLists?[mintURL.absoluteString]
    }
    
    public func deleteAccessTokenList(mintURL: URL) async throws {
        var tokenLists = try await loadAllAccessTokenLists() ?? [:]
        tokenLists.removeValue(forKey: mintURL.absoluteString)
        try await saveAllAccessTokenLists(tokenLists)
    }
    
    // MARK: - Utility Operations
    
    public func clearAll() async throws {
        let fileManager = FileManager.default
        let files = try fileManager.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: nil)
        
        for file in files {
            // Don't delete the key derivation salt
            if file.lastPathComponent != "key.enc" && file.lastPathComponent != FileName.keyDerivation {
                try fileManager.removeItem(at: file)
            }
        }
    }
    
    public func hasStoredData() async throws -> Bool {
        let hasMnemonic = try await loadMnemonic() != nil
        let hasSeed = try await loadSeed() != nil
        let hasTokens = try await loadAllAccessTokens()?.isEmpty == false
        return hasMnemonic || hasSeed || hasTokens
    }
    
    // MARK: - Private Encryption Operations
    
    private func saveEncrypted(_ value: String, to url: URL) async throws {
        guard let data = value.data(using: .utf8) else {
            throw SecureStoreError.invalidData
        }
        
        // Encrypt the data
        let encrypted = try encrypt(data)
        
        // Save to file with restricted permissions
        try encrypted.write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], // rw-------
            ofItemAtPath: url.path
        )
    }
    
    private func loadEncrypted(from url: URL) async throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        
        let encryptedData = try Data(contentsOf: url)
        let decryptedData = try decrypt(encryptedData)
        
        guard let string = String(data: decryptedData, encoding: .utf8) else {
            throw SecureStoreError.invalidData
        }
        
        return string
    }
    
    private func deleteFile(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        
        // Overwrite with random data before deletion (basic zeroization)
        if let randomData = try? SecureRandom.generateBytes(count: 1024) {
            try? randomData.write(to: url)
        }
        
        try FileManager.default.removeItem(at: url)
    }
    
    // MARK: - Encryption Helpers
    
    private func encrypt(_ data: Data) throws -> Data {
        // Generate a random nonce
        let nonce = try CryptoKit.AES.GCM.Nonce()
        
        // Encrypt the data
        let sealedBox = try CryptoKit.AES.GCM.seal(data, using: encryptionKey, nonce: nonce)
        
        // Combine nonce + ciphertext + tag
        guard let combined = sealedBox.combined else {
            throw SecureStoreError.storeFailed("Failed to create sealed box")
        }
        
        return combined
    }
    
    private func decrypt(_ data: Data) throws -> Data {
        // Create sealed box from combined data
        let sealedBox = try CryptoKit.AES.GCM.SealedBox(combined: data)
        
        // Decrypt the data
        let decrypted = try CryptoKit.AES.GCM.open(sealedBox, using: encryptionKey)
        
        return decrypted
    }
    
    // MARK: - Token Storage Helpers
    
    private func loadAllAccessTokens() async throws -> [String: String]? {
        let url = storageDirectory.appendingPathComponent(FileName.accessTokens)
        guard let jsonString = try await loadEncrypted(from: url),
              let jsonData = jsonString.data(using: .utf8) else {
            return nil
        }
        return try JSONDecoder().decode([String: String].self, from: jsonData)
    }
    
    private func saveAllAccessTokens(_ tokens: [String: String]) async throws {
        let url = storageDirectory.appendingPathComponent(FileName.accessTokens)
        let jsonData = try JSONEncoder().encode(tokens)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw SecureStoreError.invalidData
        }
        try await saveEncrypted(jsonString, to: url)
    }
    
    private func loadAllAccessTokenLists() async throws -> [String: [String]]? {
        let url = storageDirectory.appendingPathComponent(FileName.accessTokenLists)
        guard let jsonString = try await loadEncrypted(from: url),
              let jsonData = jsonString.data(using: .utf8) else {
            return nil
        }
        return try JSONDecoder().decode([String: [String]].self, from: jsonData)
    }
    
    private func saveAllAccessTokenLists(_ tokenLists: [String: [String]]) async throws {
        let url = storageDirectory.appendingPathComponent(FileName.accessTokenLists)
        let jsonData = try JSONEncoder().encode(tokenLists)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw SecureStoreError.invalidData
        }
        try await saveEncrypted(jsonString, to: url)
    }
    
    // MARK: - Key Management
    
    private static func deriveKey(from password: String, storageDirectory: URL) async throws -> SymmetricKey {
        let saltURL = storageDirectory.appendingPathComponent(FileName.keyDerivation)
        
        let salt: Data
        if FileManager.default.fileExists(atPath: saltURL.path) {
            salt = try Data(contentsOf: saltURL)
        } else {
            // Generate new salt
            salt = try SecureRandom.generateBytes(count: 32)
            try salt.write(to: saltURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: saltURL.path
            )
        }
        
        // Derive key using PBKDF2
        let passwordData = password.data(using: .utf8) ?? Data()
        let keyData = try PKCS5.PBKDF2(
            password: Array(passwordData),
            salt: Array(salt),
            iterations: 100_000,
            keyLength: 32,
            variant: .sha2(.sha256)
        ).calculate()
        
        return SymmetricKey(data: Data(keyData))
    }
    
    private static func generateOrLoadKey(storageDirectory: URL) async throws -> SymmetricKey {
        let keyURL = storageDirectory.appendingPathComponent("key.enc")
        
        if FileManager.default.fileExists(atPath: keyURL.path) {
            let keyData = try Data(contentsOf: keyURL)
            return SymmetricKey(data: keyData)
        } else {
            // Generate new key
            let key = SymmetricKey(size: .bits256)
            let keyData = key.withUnsafeBytes { Data($0) }
            try keyData.write(to: keyURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: keyURL.path
            )
            return key
        }
    }
}

// MARK: - Convenience Factory

public extension FileSecureStore {
    /// Create a default file-based store with auto-generated key
    static func `default`() async throws -> FileSecureStore {
        return try await FileSecureStore()
    }
    
    /// Create a password-protected file-based store
    /// - Parameter password: The password for key derivation
    static func withPassword(_ password: String) async throws -> FileSecureStore {
        return try await FileSecureStore(password: password)
    }
    
    /// Create a file-based store in a custom directory
    /// - Parameters:
    ///   - directory: The directory to use for storage
    ///   - password: Optional password for key derivation
    static func withDirectory(_ directory: URL, password: String? = nil) async throws -> FileSecureStore {
        return try await FileSecureStore(directory: directory, password: password)
    }
}