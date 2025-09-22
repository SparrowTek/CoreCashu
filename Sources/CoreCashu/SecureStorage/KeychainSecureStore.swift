#if canImport(Security) && !os(Linux)
import Foundation
import Security

/// Keychain-backed secure store for Apple platforms.
/// Uses kSecClassGenericPassword items namespaced under a configurable service prefix.
public actor KeychainSecureStore: SecureStore {

    public struct Configuration: Sendable {
        public enum AccessControlPolicy: Sendable {
            case userPresence
            case biometryAny
            case biometryCurrentSet
            case devicePasscode
            case custom(rawValue: UInt)

            fileprivate var flags: SecAccessControlCreateFlags {
                switch self {
                case .userPresence:
                    return [.userPresence]
                case .biometryAny:
                    return [.userPresence, .biometryAny]
                case .biometryCurrentSet:
                    return [.userPresence, .biometryCurrentSet]
                case .devicePasscode:
                    return [.devicePasscode]
                case .custom(let rawValue):
                    return SecAccessControlCreateFlags(rawValue: rawValue)
                }
            }
        }

        public let servicePrefix: String
        public let accessGroup: String?
        public let accessibility: String
        public let accessControl: AccessControlPolicy?

        public init(
            servicePrefix: String = "cashu.core",
            accessGroup: String? = nil,
            accessibility: String = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
            accessControl: AccessControlPolicy? = nil
        ) {
            self.servicePrefix = servicePrefix
            self.accessGroup = accessGroup
            self.accessibility = accessibility
            self.accessControl = accessControl
        }
    }

    private let configuration: Configuration

    private enum ItemKind: String {
        case mnemonic
        case seed
        case accessTokens
        case accessTokenLists

        func service(using prefix: String) -> String { "\(prefix).\(rawValue)" }
        func account(using prefix: String) -> String { "\(prefix).account.\(rawValue)" }
        var logName: String { rawValue }
    }

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - Mnemonic Operations

    public func saveMnemonic(_ mnemonic: String) async throws {
        try storeString(mnemonic, kind: .mnemonic)
    }

    public func loadMnemonic() async throws -> String? {
        try loadString(kind: .mnemonic)
    }

    public func deleteMnemonic() async throws {
        try deleteItem(kind: .mnemonic)
    }

    // MARK: - Seed Operations

    public func saveSeed(_ seed: String) async throws {
        try storeString(seed, kind: .seed)
    }

    public func loadSeed() async throws -> String? {
        try loadString(kind: .seed)
    }

    public func deleteSeed() async throws {
        try deleteItem(kind: .seed)
    }

    // MARK: - Access Token Operations

    public func saveAccessToken(_ token: String, mintURL: URL) async throws {
        var tokens = try loadAllAccessTokens() ?? [:]
        tokens[mintURL.absoluteString] = token
        try storeAccessTokens(tokens)
    }

    public func loadAccessToken(mintURL: URL) async throws -> String? {
        let tokens = try loadAllAccessTokens()
        return tokens?[mintURL.absoluteString]
    }

    public func deleteAccessToken(mintURL: URL) async throws {
        guard var tokens = try loadAllAccessTokens() else { return }
        tokens.removeValue(forKey: mintURL.absoluteString)
        if tokens.isEmpty {
            try deleteItem(kind: .accessTokens)
        } else {
            try storeAccessTokens(tokens)
        }
    }

    // MARK: - Access Token List Operations

    public func saveAccessTokenList(_ tokens: [String], mintURL: URL) async throws {
        var tokenLists = try loadAllAccessTokenLists() ?? [:]
        tokenLists[mintURL.absoluteString] = tokens
        try storeAccessTokenLists(tokenLists)
    }

    public func loadAccessTokenList(mintURL: URL) async throws -> [String]? {
        let tokenLists = try loadAllAccessTokenLists()
        return tokenLists?[mintURL.absoluteString]
    }

    public func deleteAccessTokenList(mintURL: URL) async throws {
        guard var tokenLists = try loadAllAccessTokenLists() else { return }
        tokenLists.removeValue(forKey: mintURL.absoluteString)
        if tokenLists.isEmpty {
            try deleteItem(kind: .accessTokenLists)
        } else {
            try storeAccessTokenLists(tokenLists)
        }
    }

    // MARK: - Utility Operations

    public func clearAll() async throws {
        try deleteItem(kind: .mnemonic)
        try deleteItem(kind: .seed)
        try deleteItem(kind: .accessTokens)
        try deleteItem(kind: .accessTokenLists)
    }

    public func hasStoredData() async throws -> Bool {
        if try loadData(kind: .mnemonic) != nil { return true }
        if try loadData(kind: .seed) != nil { return true }
        if let tokens = try loadAllAccessTokens(), tokens.isEmpty == false { return true }
        if let lists = try loadAllAccessTokenLists(), lists.isEmpty == false { return true }
        return false
    }

    // MARK: - Private Helpers

    private func storeString(_ value: String, kind: ItemKind) throws {
        guard let data = value.data(using: .utf8) else {
            throw SecureStoreError.invalidData
        }
        try storeData(data, kind: kind)
    }

    private func loadString(kind: ItemKind) throws -> String? {
        guard let data = try loadData(kind: kind) else { return nil }
        guard let string = String(data: data, encoding: .utf8) else {
            throw SecureStoreError.invalidData
        }
        return string
    }

    private func storeAccessTokens(_ tokens: [String: String]) throws {
        let data = try JSONEncoder().encode(tokens)
        try storeData(data, kind: .accessTokens)
    }

    private func loadAllAccessTokens() throws -> [String: String]? {
        guard let data = try loadData(kind: .accessTokens) else { return nil }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    private func storeAccessTokenLists(_ tokenLists: [String: [String]]) throws {
        let data = try JSONEncoder().encode(tokenLists)
        try storeData(data, kind: .accessTokenLists)
    }

    private func loadAllAccessTokenLists() throws -> [String: [String]]? {
        guard let data = try loadData(kind: .accessTokenLists) else { return nil }
        return try JSONDecoder().decode([String: [String]].self, from: data)
    }

    private func storeData(_ data: Data, kind: ItemKind) throws {
        var attributes = baseAttributes(for: kind)
        attributes[kSecValueData as String] = data

        if let policy = configuration.accessControl {
            attributes[kSecAttrAccessControl as String] = try makeAccessControl(for: policy)
        } else {
            attributes[kSecAttrAccessible as String] = configuration.accessibility as CFString
        }

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let query = baseQuery(for: kind)
            let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw mapError(status: updateStatus, category: .store, context: "update \(kind.logName)")
            }
        } else if status != errSecSuccess {
            throw mapError(status: status, category: .store, context: "store \(kind.logName)")
        }
    }

    private func loadData(kind: ItemKind) throws -> Data? {
        var query = baseQuery(for: kind)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw mapError(status: status, category: .retrieval, context: "load \(kind.logName)")
        }
        guard let data = item as? Data else {
            throw SecureStoreError.invalidData
        }
        return data
    }

    private func deleteItem(kind: ItemKind) throws {
        let query = baseQuery(for: kind)
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else {
            throw mapError(status: status, category: .deletion, context: "delete \(kind.logName)")
        }
    }

    private func makeAccessControl(for policy: Configuration.AccessControlPolicy) throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(
            nil,
            configuration.accessibility as CFString,
            policy.flags,
            &error
        ) else {
            let description = error?.takeRetainedValue().localizedDescription ?? "Unknown failure"
            throw SecureStoreError.storeFailed("access control creation failed: \(description)")
        }
        return control
    }

    private func baseAttributes(for kind: ItemKind) -> [String: Any] {
        var attributes = baseQuery(for: kind)
        if let accessGroup = configuration.accessGroup {
            attributes[kSecAttrAccessGroup as String] = accessGroup
        }
        return attributes
    }

    private func baseQuery(for kind: ItemKind) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kind.service(using: configuration.servicePrefix),
            kSecAttrAccount as String: kind.account(using: configuration.servicePrefix)
        ]

        if let accessGroup = configuration.accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        return query
    }

    private enum ErrorCategory {
        case store
        case retrieval
        case deletion
    }

    private func mapError(status: OSStatus, category: ErrorCategory, context: String) -> SecureStoreError {
        let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "status \(status)"
        let reason = "\(context): \(message)"
        switch category {
        case .store:
            return .storeFailed(reason)
        case .retrieval:
            return .retrievalFailed(reason)
        case .deletion:
            return .deletionFailed(reason)
        }
    }
}

#endif
