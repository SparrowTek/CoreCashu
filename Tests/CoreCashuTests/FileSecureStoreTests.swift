#if !os(WASI)
import Testing
@testable import CoreCashu
import Foundation

@Suite("FileSecureStore", .serialized)
struct FileSecureStoreTests {

    @Test("Mnemonic and seed persistence")
    func mnemonicAndSeedPersistence() async throws {
        let directory = try temporaryDirectory()
        let store = try await FileSecureStore(directory: directory)

        let mnemonic = "abandon ability able about above absent absorb abstract absurd abuse"
        let seed = "deadbeef"

        try await store.saveMnemonic(mnemonic)
        try await store.saveSeed(seed)

        #expect(try await store.loadMnemonic() == mnemonic)
        #expect(try await store.loadSeed() == seed)

#if !os(Windows)
        let mnemonicAttributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("mnemonic.enc").path)
        let mnemonicMode = mnemonicAttributes[.posixPermissions] as? NSNumber
        #expect(mnemonicMode?.intValue == 0o600)
#endif

        try await store.clearAll()
        #expect(try await store.hasStoredData() == false)
    }

    @Test("Access token persistence")
    func accessTokenPersistence() async throws {
        let directory = try temporaryDirectory()
        let store = try await FileSecureStore(directory: directory)
        let mint = URL(string: "https://mint.example.com")!

        try await store.saveAccessToken("tokenA", mintURL: mint)
        try await store.saveAccessTokenList(["tokenA", "tokenB"], mintURL: mint)

        #expect(try await store.loadAccessToken(mintURL: mint) == "tokenA")
        #expect(try await store.loadAccessTokenList(mintURL: mint) == ["tokenA", "tokenB"])

        try await store.deleteAccessToken(mintURL: mint)
        try await store.deleteAccessTokenList(mintURL: mint)

        #expect(try await store.loadAccessToken(mintURL: mint) == nil)
        #expect(try await store.loadAccessTokenList(mintURL: mint) == nil)
    }

    @Test("Key rotation re-encrypts data")
    func keyRotationReencryptsData() async throws {
        let directory = try temporaryDirectory()
        let store = try await FileSecureStore(directory: directory)
        let fileURL = directory.appendingPathComponent("mnemonic.enc")

        try await store.saveMnemonic("abandon ability able about above absent absorb abstract absurd abuse")
        let originalCiphertext = try Data(contentsOf: fileURL)

        try await store.rotateMasterKey()

        let rotatedCiphertext = try Data(contentsOf: fileURL)
        #expect(originalCiphertext != rotatedCiphertext)
        #expect(try await store.loadMnemonic() == "abandon ability able about above absent absorb abstract absurd abuse")
    }

    @Test("Password protected store survives rotation")
    func passwordProtectedStoreSurvivesRotation() async throws {
        let directory = try temporaryDirectory()
        let configuration = FileSecureStore.Configuration(
            directory: directory,
            password: "strong-passphrase",
            pbkdfRounds: 25_000
        )
        let store = try await FileSecureStore(configuration: configuration)

        try await store.saveSeed("0123456789abcdef")
        #expect(try await store.loadSeed() == "0123456789abcdef")

        try await store.rotateMasterKey(newPassword: "new-passphrase")
        #expect(try await store.loadSeed() == "0123456789abcdef")
    }

    private func temporaryDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("cashu-secure-store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
#endif
