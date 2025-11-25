#if TESTING && canImport(Security) && !os(Linux)
import Testing
@testable import CoreCashu
import Foundation

@Suite("KeychainSecureStore (Testing Shim)", .serialized)
struct KeychainSecureStoreShimTests {

    @Test("Mnemonic lifecycle on shim")
    func mnemonicLifecycleOnShim() async throws {
        let store = InMemoryKeychainSecureStore()
        let mnemonic = "abandon ability able about above absent absorb abstract absurd abuse"

        try await store.saveMnemonic(mnemonic)
        #expect(try await store.loadMnemonic() == mnemonic)

        try await store.deleteMnemonic()
        #expect(try await store.loadMnemonic() == nil)
    }

    @Test("Access token round trip on shim")
    func accessTokenRoundTripOnShim() async throws {
        let store = InMemoryKeychainSecureStore()
        let mintURL = URL(string: "https://mint.example.com")!
        try await store.saveAccessToken("token-123", mintURL: mintURL)
        try await store.saveAccessTokenList(["token-123", "token-456"], mintURL: mintURL)

        #expect(try await store.loadAccessToken(mintURL: mintURL) == "token-123")
        #expect(try await store.loadAccessTokenList(mintURL: mintURL) == ["token-123", "token-456"])

        try await store.clearAll()
        #expect(try await store.hasStoredData() == false)
    }
}

private actor InMemoryKeychainSecureStore: SecureStore {
    private enum StorageKey: Hashable {
        case mnemonic
        case seed
        case accessTokens
        case accessTokenLists
    }

    private var storage: [StorageKey: Data] = [:]

    func saveMnemonic(_ mnemonic: String) async throws {
        try saveString(mnemonic, kind: .mnemonic)
    }

    func loadMnemonic() async throws -> String? {
        try loadString(kind: .mnemonic)
    }

    func deleteMnemonic() async throws {
        storage.removeValue(forKey: .mnemonic)
    }

    func saveSeed(_ seed: String) async throws {
        try saveString(seed, kind: .seed)
    }

    func loadSeed() async throws -> String? {
        try loadString(kind: .seed)
    }

    func deleteSeed() async throws {
        storage.removeValue(forKey: .seed)
    }

    func saveAccessToken(_ token: String, mintURL: URL) async throws {
        var tokens = try loadAccessTokens() ?? [:]
        tokens[mintURL.absoluteString] = token
        try storeAccessTokens(tokens)
    }

    func loadAccessToken(mintURL: URL) async throws -> String? {
        let tokens = try loadAccessTokens()
        return tokens?[mintURL.absoluteString]
    }

    func deleteAccessToken(mintURL: URL) async throws {
        guard var tokens = try loadAccessTokens() else { return }
        tokens.removeValue(forKey: mintURL.absoluteString)
        if tokens.isEmpty {
            storage.removeValue(forKey: .accessTokens)
        } else {
            try storeAccessTokens(tokens)
        }
    }

    func saveAccessTokenList(_ tokens: [String], mintURL: URL) async throws {
        var lists = try loadAccessTokenLists() ?? [:]
        lists[mintURL.absoluteString] = tokens
        try storeAccessTokenLists(lists)
    }

    func loadAccessTokenList(mintURL: URL) async throws -> [String]? {
        let lists = try loadAccessTokenLists()
        return lists?[mintURL.absoluteString]
    }

    func deleteAccessTokenList(mintURL: URL) async throws {
        guard var lists = try loadAccessTokenLists() else { return }
        lists.removeValue(forKey: mintURL.absoluteString)
        if lists.isEmpty {
            storage.removeValue(forKey: .accessTokenLists)
        } else {
            try storeAccessTokenLists(lists)
        }
    }

    func clearAll() async throws {
        storage.removeAll()
    }

    func hasStoredData() async throws -> Bool {
        !storage.isEmpty
    }

    private func saveString(_ value: String, kind: StorageKey) throws {
        guard let data = value.data(using: .utf8) else {
            throw SecureStoreError.invalidData
        }
        storage[kind] = data
    }

    private func loadString(kind: StorageKey) throws -> String? {
        guard let data = storage[kind] else { return nil }
        guard let string = String(data: data, encoding: .utf8) else {
            throw SecureStoreError.invalidData
        }
        return string
    }

    private func loadAccessTokens() throws -> [String: String]? {
        try loadDictionary(kind: .accessTokens)
    }

    private func storeAccessTokens(_ tokens: [String: String]) throws {
        try storeDictionary(tokens, kind: .accessTokens)
    }

    private func loadAccessTokenLists() throws -> [String: [String]]? {
        try loadDictionary(kind: .accessTokenLists)
    }

    private func storeAccessTokenLists(_ lists: [String: [String]]) throws {
        try storeDictionary(lists, kind: .accessTokenLists)
    }

    private func loadDictionary<T: Decodable>(kind: StorageKey) throws -> T? {
        guard let data = storage[kind] else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func storeDictionary<T: Encodable>(_ value: T, kind: StorageKey) throws {
        let data = try JSONEncoder().encode(value)
        storage[kind] = data
    }
}
#endif
