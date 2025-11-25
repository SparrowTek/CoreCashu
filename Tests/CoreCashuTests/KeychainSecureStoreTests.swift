#if canImport(Security) && !os(Linux)
import Testing
@testable import CoreCashu
import Foundation

@Suite("KeychainSecureStore", .serialized)
struct KeychainSecureStoreTests {
    private func uniqueConfiguration(label: String = UUID().uuidString) -> KeychainSecureStore.Configuration {
        KeychainSecureStore.Configuration(
            servicePrefix: "cashu.tests.\(label)"
        )
    }

    @Test("Mnemonic round trip")
    func mnemonicRoundTrip() async throws {
        let configuration = uniqueConfiguration(label: "mnemonic")
        let store = KeychainSecureStore(configuration: configuration)

        let mnemonic = "abandon ability able about above absent absorb abstract absurd abuse"
        try await store.saveMnemonic(mnemonic)

        let loaded = try await store.loadMnemonic()
        #expect(loaded == mnemonic)

        try await store.clearAll()
    }

    @Test("Access tokens persistence")
    func accessTokensPersistence() async throws {
        let configuration = uniqueConfiguration(label: "tokens")
        let store = KeychainSecureStore(configuration: configuration)

        let mintURL = URL(string: "https://mint.example.com")!
        try await store.saveAccessToken("tokenA", mintURL: mintURL)
        try await store.saveAccessTokenList(["t1", "t2"], mintURL: mintURL)

        let token = try await store.loadAccessToken(mintURL: mintURL)
        let list = try await store.loadAccessTokenList(mintURL: mintURL)

        #expect(token == "tokenA")
        #expect(list == ["t1", "t2"])

        try await store.deleteAccessToken(mintURL: mintURL)
        try await store.deleteAccessTokenList(mintURL: mintURL)

        #expect(try await store.loadAccessToken(mintURL: mintURL) == nil)
        #expect(try await store.loadAccessTokenList(mintURL: mintURL) == nil)

        try await store.clearAll()
    }

    @Test("hasStoredData reflects Keychain state")
    func hasStoredDataReflectsState() async throws {
        let configuration = uniqueConfiguration(label: "presence")
        let store = KeychainSecureStore(configuration: configuration)

        #expect(try await store.hasStoredData() == false)

        try await store.saveSeed("deadbeef")
        #expect(try await store.hasStoredData())

        try await store.clearAll()
        #expect(try await store.hasStoredData() == false)
    }

    @Test("User presence access control prevents background reads")
    func userPresenceAccessControlPreventsBackgroundReads() async throws {
        let configuration = KeychainSecureStore.Configuration(
            servicePrefix: "cashu.tests.userpresence.\(UUID().uuidString)",
            accessControl: .userPresence
        )
        let store = KeychainSecureStore(configuration: configuration)

        var saveError: SecureStoreError?
        do {
            try await store.saveMnemonic("abandon ability able about above absent absorb abstract absurd abuse")
        } catch let secureError as SecureStoreError {
            saveError = secureError
        }

        if let saveError {
            let missingEntitlement: Bool
            if case .storeFailed = saveError {
                missingEntitlement = true
            } else {
                missingEntitlement = false
            }
            #expect(missingEntitlement)
            return
        }

        var thrownError: Error?
        do {
            _ = try await store.loadMnemonic()
        } catch {
            thrownError = error
        }

        let requiresPresence: Bool
        if let secureError = thrownError as? SecureStoreError,
           case .retrievalFailed = secureError {
            requiresPresence = true
        } else {
            requiresPresence = false
        }

        #expect(requiresPresence)

        try await store.clearAll()
    }

    @Test("Wallet configuration exposes Keychain access control")
    func walletConfigurationExposesKeychainAccessControl() {
        let configuration = WalletConfiguration(
            mintURL: "https://mint.example.com",
            keychainAccessControl: .biometryCurrentSet
        )

        let keychainConfiguration = configuration.keychainConfiguration
        switch keychainConfiguration.accessControl {
        case .biometryCurrentSet?:
            #expect(Bool(true))
        default:
            #expect(Bool(false), "Expected biometryCurrentSet access control")
        }
    }
}
#endif
