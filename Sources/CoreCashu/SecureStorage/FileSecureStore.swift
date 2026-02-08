//
//  FileSecureStore.swift
//  CoreCashu
//
//  Hardened file-based secure storage for Linux and other non-Keychain platforms.
//

import Foundation
import CryptoSwift

/// File-backed secure store that encrypts wallet material at rest using AES-GCM.
/// Suitable for Linux and other platforms where a system keychain is unavailable.
public actor FileSecureStore: SecureStore {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public struct FileNames: Sendable, Codable {
            public var mnemonic: String
            public var seed: String
            public var accessTokens: String
            public var accessTokenLists: String

            public init(
                mnemonic: String = "mnemonic.enc",
                seed: String = "seed.enc",
                accessTokens: String = "access_tokens.enc",
                accessTokenLists: String = "access_token_lists.enc"
            ) {
                self.mnemonic = mnemonic
                self.seed = seed
                self.accessTokens = accessTokens
                self.accessTokenLists = accessTokenLists
            }

            public static let `default` = FileNames()
        }

        public var directory: URL?
        public var password: String?
        public var fileNames: FileNames
        public var keyMaterialFileName: String
        public var pbkdfRounds: Int
        public var nonceLength: Int

        public init(
            directory: URL? = nil,
            password: String? = nil,
            fileNames: FileNames = .default,
            keyMaterialFileName: String = "secure_store_master_key.json",
            pbkdfRounds: Int = CryptoConstants.pbkdfRounds,
            nonceLength: Int = CryptoConstants.gcmNonceLength
        ) {
            self.directory = directory
            self.password = password
            self.fileNames = fileNames
            self.keyMaterialFileName = keyMaterialFileName
            self.pbkdfRounds = pbkdfRounds
            self.nonceLength = nonceLength
        }
    }

    private struct KeyState {
        var keyBytes: [UInt8]
        var metadata: KeyMetadata
    }

    private struct KeyMetadata: Codable, Sendable {
        var version: Int
        var keyId: UUID
        var createdAt: Date
        var salt: Data?
        var pbkdfRounds: Int?
    }

    private struct KeyContainer: Codable {
        var metadata: KeyMetadata
        var keyData: Data?
    }

    private enum StorageKind {
        case mnemonic
        case seed
        case accessTokens
        case accessTokenLists

        func fileName(using names: Configuration.FileNames) -> String {
            switch self {
            case .mnemonic:
                return names.mnemonic
            case .seed:
                return names.seed
            case .accessTokens:
                return names.accessTokens
            case .accessTokenLists:
                return names.accessTokenLists
            }
        }
    }

    private static let envelopeVersion: UInt8 = 1

    private var configuration: Configuration
    private let storageDirectory: URL
    private var keyState: KeyState

    // MARK: - Lifecycle

    public init(directory: URL? = nil, password: String? = nil) async throws {
        let configuration = Configuration(directory: directory, password: password)
        try await self.init(configuration: configuration)
    }

    public init(configuration: Configuration) async throws {
        self.configuration = configuration
        self.storageDirectory = Self.resolveDirectory(configuration.directory)
        try Self.prepareDirectory(storageDirectory)
        self.keyState = try Self.bootstrapKeyState(
            configuration: configuration,
            storageDirectory: storageDirectory,
            rotating: false
        )
    }

    // MARK: - SecureStore

    public func saveMnemonic(_ mnemonic: String) async throws {
        try saveString(mnemonic, kind: .mnemonic)
    }

    public func loadMnemonic() async throws -> String? {
        try loadString(kind: .mnemonic)
    }

    public func deleteMnemonic() async throws {
        try delete(kind: .mnemonic)
    }

    public func saveSeed(_ seed: String) async throws {
        try saveString(seed, kind: .seed)
    }

    public func loadSeed() async throws -> String? {
        try loadString(kind: .seed)
    }

    public func deleteSeed() async throws {
        try delete(kind: .seed)
    }

    public func saveAccessToken(_ token: String, mintURL: URL) async throws {
        var tokens = try loadAccessTokensDictionary()
        tokens[mintURL.absoluteString] = token
        try saveAccessTokensDictionary(tokens)
    }

    public func loadAccessToken(mintURL: URL) async throws -> String? {
        let tokens = try loadAccessTokensDictionary()
        return tokens[mintURL.absoluteString]
    }

    public func deleteAccessToken(mintURL: URL) async throws {
        var tokens = try loadAccessTokensDictionary()
        tokens.removeValue(forKey: mintURL.absoluteString)
        try saveAccessTokensDictionary(tokens)
    }

    public func saveAccessTokenList(_ tokens: [String], mintURL: URL) async throws {
        var tokenLists = try loadAccessTokenListsDictionary()
        tokenLists[mintURL.absoluteString] = tokens
        try saveAccessTokenListsDictionary(tokenLists)
    }

    public func loadAccessTokenList(mintURL: URL) async throws -> [String]? {
        let tokenLists = try loadAccessTokenListsDictionary()
        return tokenLists[mintURL.absoluteString]
    }

    public func deleteAccessTokenList(mintURL: URL) async throws {
        var tokenLists = try loadAccessTokenListsDictionary()
        tokenLists.removeValue(forKey: mintURL.absoluteString)
        try saveAccessTokenListsDictionary(tokenLists)
    }

    public func clearAll() async throws {
        try delete(kind: .mnemonic)
        try delete(kind: .seed)
        try delete(kind: .accessTokens)
        try delete(kind: .accessTokenLists)
    }

    public func hasStoredData() async throws -> Bool {
        let hasMnemonic = try loadString(kind: .mnemonic) != nil
        let hasSeed = try loadString(kind: .seed) != nil
        let hasTokens = try loadAccessTokensDictionary().isEmpty == false
        let hasTokenLists = try loadAccessTokenListsDictionary().isEmpty == false
        return hasMnemonic || hasSeed || hasTokens || hasTokenLists
    }

    // MARK: - Key Rotation

    /// Rotate the master encryption key and re-encrypt persisted data.
    /// - Parameter newPassword: Optional password to use for the refreshed key. Defaults to the current configuration.
    public func rotateMasterKey(newPassword: String? = nil) async throws {
        let mnemonic = try loadString(kind: .mnemonic)
        let seed = try loadString(kind: .seed)
        let tokens = try loadAccessTokensDictionary()
        let tokenLists = try loadAccessTokenListsDictionary()

        if let newPassword {
            configuration.password = newPassword
        }

        keyState = try Self.bootstrapKeyState(
            configuration: configuration,
            storageDirectory: storageDirectory,
            rotating: true
        )

        if let mnemonic {
            try saveString(mnemonic, kind: .mnemonic)
        } else {
            try delete(kind: .mnemonic)
        }

        if let seed {
            try saveString(seed, kind: .seed)
        } else {
            try delete(kind: .seed)
        }

        if tokens.isEmpty {
            try delete(kind: .accessTokens)
        } else {
            try saveAccessTokensDictionary(tokens)
        }

        if tokenLists.isEmpty {
            try delete(kind: .accessTokenLists)
        } else {
            try saveAccessTokenListsDictionary(tokenLists)
        }
    }

    // MARK: - Persistence Helpers

    private func saveString(_ value: String, kind: StorageKind) throws {
        guard let data = value.data(using: .utf8) else {
            throw SecureStoreError.invalidData
        }
        try saveData(data, kind: kind)
    }

    private func loadString(kind: StorageKind) throws -> String? {
        guard let data = try loadData(kind: kind) else {
            return nil
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw SecureStoreError.invalidData
        }
        return string
    }

    private func saveData(_ data: Data, kind: StorageKind) throws {
        let encrypted = try encrypt(data)
        let url = path(for: kind)
        try encrypted.write(to: url, options: .atomic)
        try Self.hardenFile(at: url)
    }

    private func loadData(kind: StorageKind) throws -> Data? {
        let url = path(for: kind)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let envelope = try Data(contentsOf: url)
        return try decrypt(envelope)
    }

    private func delete(kind: StorageKind) throws {
        let url = path(for: kind)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        // Overwrite with random bytes before removal (best-effort sanitisation)
        if let filler = try? SecureRandom.generateBytes(count: CryptoConstants.secureOverwriteSize) {
            try? filler.write(to: url, options: .atomic)
        }

        try FileManager.default.removeItem(at: url)
    }

    private func path(for kind: StorageKind) -> URL {
        storageDirectory.appendingPathComponent(kind.fileName(using: configuration.fileNames))
    }

    // MARK: - Token dictionary helpers

    private func loadAccessTokensDictionary() throws -> [String: String] {
        guard let data = try loadData(kind: .accessTokens) else {
            return [:]
        }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    private func saveAccessTokensDictionary(_ tokens: [String: String]) throws {
        let data = try JSONEncoder().encode(tokens)
        try saveData(data, kind: .accessTokens)
    }

    private func loadAccessTokenListsDictionary() throws -> [String: [String]] {
        guard let data = try loadData(kind: .accessTokenLists) else {
            return [:]
        }
        return try JSONDecoder().decode([String: [String]].self, from: data)
    }

    private func saveAccessTokenListsDictionary(_ tokenLists: [String: [String]]) throws {
        let data = try JSONEncoder().encode(tokenLists)
        try saveData(data, kind: .accessTokenLists)
    }

    // MARK: - Encryption / Decryption

    private func encrypt(_ plaintext: Data) throws -> Data {
        let nonceData = try SecureRandom.generateBytes(count: configuration.nonceLength)
        let nonceBytes = Array(nonceData)
        let gcm = GCM(iv: nonceBytes, tagLength: CryptoConstants.gcmTagLength, mode: .combined)
        let aes = try AES(key: keyState.keyBytes, blockMode: gcm, padding: .noPadding)
        let ciphertext = try aes.encrypt(Array(plaintext))

        var envelope = Data()
        envelope.append(Self.envelopeVersion)
        envelope.append(UInt8(nonceBytes.count))
        envelope.append(contentsOf: nonceBytes)
        envelope.append(contentsOf: ciphertext)
        return envelope
    }

    private func decrypt(_ envelope: Data) throws -> Data {
        let bytes = Array(envelope)
        guard bytes.count > 2 else {
            throw SecureStoreError.invalidData
        }

        let version = bytes[0]
        guard version == Self.envelopeVersion else {
            throw SecureStoreError.retrievalFailed("Unsupported envelope version \(version)")
        }

        let nonceLength = Int(bytes[1])
        guard nonceLength > 0, bytes.count >= 2 + nonceLength else {
            throw SecureStoreError.retrievalFailed("Corrupted envelope header")
        }

        let nonce = Array(bytes[2..<(2 + nonceLength)])
        let ciphertext = Array(bytes[(2 + nonceLength)...])

        let gcm = GCM(iv: nonce, tagLength: CryptoConstants.gcmTagLength, mode: .combined)
        let aes = try AES(key: keyState.keyBytes, blockMode: gcm, padding: .noPadding)

        let plaintext = try aes.decrypt(ciphertext)
        return Data(plaintext)
    }

    // MARK: - Key Bootstrap & Persistence

    private static func resolveDirectory(_ directory: URL?) -> URL {
        if let directory {
            return directory
        }
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        #else
        let base = FileManager.default.homeDirectoryForCurrentUser
        #endif
        return base.appendingPathComponent(".cashu/secure")
    }

    private static func prepareDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: FileSystemConstants.directoryPermissions]
        )
    }

    private static func hardenFile(at url: URL) throws {
        try FileManager.default.setAttributes([
            .posixPermissions: FileSystemConstants.filePermissions
        ], ofItemAtPath: url.path)
    }

    private static func bootstrapKeyState(
        configuration: Configuration,
        storageDirectory: URL,
        rotating: Bool
    ) throws -> KeyState {
        let keyURL = storageDirectory.appendingPathComponent(configuration.keyMaterialFileName)

        if rotating {
            return try createKeyState(
                configuration: configuration,
                storageDirectory: storageDirectory,
                keyURL: keyURL,
                overwrite: true
            )
        }

        if FileManager.default.fileExists(atPath: keyURL.path) {
            return try loadExistingKeyState(
                configuration: configuration,
                keyURL: keyURL
            )
        } else {
            return try createKeyState(
                configuration: configuration,
                storageDirectory: storageDirectory,
                keyURL: keyURL,
                overwrite: false
            )
        }
    }

    private static func loadExistingKeyState(
        configuration: Configuration,
        keyURL: URL
    ) throws -> KeyState {
        let data = try Data(contentsOf: keyURL)
        let container = try JSONDecoder().decode(KeyContainer.self, from: data)

        if let keyData = container.keyData {
            return KeyState(keyBytes: Array(keyData), metadata: container.metadata)
        }

        guard let password = configuration.password,
              let salt = container.metadata.salt,
              let rounds = container.metadata.pbkdfRounds else {
            throw SecureStoreError.retrievalFailed("Missing key material or password for file-based secure store")
        }

        let keyBytes = try deriveKey(
            password: password,
            salt: salt,
            rounds: rounds
        )

        return KeyState(keyBytes: keyBytes, metadata: container.metadata)
    }

    private static func createKeyState(
        configuration: Configuration,
        storageDirectory: URL,
        keyURL: URL,
        overwrite: Bool
    ) throws -> KeyState {
        if overwrite, FileManager.default.fileExists(atPath: keyURL.path) {
            try FileManager.default.removeItem(at: keyURL)
        }

        let metadata = KeyMetadata(
            version: 1,
            keyId: UUID(),
            createdAt: Date(),
            salt: nil,
            pbkdfRounds: nil
        )

        let container: KeyContainer
        let keyBytes: [UInt8]

        if let password = configuration.password {
            let salt = try SecureRandom.generateBytes(count: CryptoConstants.saltLength)
            let derivedKey = try deriveKey(
                password: password,
                salt: salt,
                rounds: configuration.pbkdfRounds
            )
            keyBytes = derivedKey
            let saltedMetadata = KeyMetadata(
                version: metadata.version,
                keyId: metadata.keyId,
                createdAt: metadata.createdAt,
                salt: salt,
                pbkdfRounds: configuration.pbkdfRounds
            )
            container = KeyContainer(metadata: saltedMetadata, keyData: nil)
        } else {
            let keyData = try SecureRandom.generateBytes(count: CryptoConstants.aesKeyLength)
            keyBytes = Array(keyData)
            container = KeyContainer(metadata: metadata, keyData: keyData)
        }

        let encoded = try JSONEncoder().encode(container)
        try encoded.write(to: keyURL, options: .atomic)
        try hardenFile(at: keyURL)

        return KeyState(keyBytes: keyBytes, metadata: container.metadata)
    }

    private static func deriveKey(password: String, salt: Data, rounds: Int) throws -> [UInt8] {
        let passwordBytes = Array(password.utf8)
        let saltBytes = Array(salt)
        let derived = try PKCS5.PBKDF2(
            password: passwordBytes,
            salt: saltBytes,
            iterations: rounds,
            keyLength: CryptoConstants.aesKeyLength,
            variant: .sha2(.sha256)
        ).calculate()
        return derived
    }
}

// MARK: - Convenience factories

public extension FileSecureStore {
    static func `default`() async throws -> FileSecureStore {
        try await FileSecureStore()
    }

    static func withPassword(_ password: String) async throws -> FileSecureStore {
        try await FileSecureStore(password: password)
    }

    static func withDirectory(_ directory: URL, password: String? = nil) async throws -> FileSecureStore {
        try await FileSecureStore(directory: directory, password: password)
    }
}
