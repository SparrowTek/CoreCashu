#if !os(WASI)
import Testing
@testable import CoreCashu
import Foundation

@Suite("FileSecureStore", .serialized)
struct FileSecureStoreTests {

    @Test("Mnemonic and seed persistence")
    func mnemonicAndSeedPersistence() async throws {
        let directory = try temporaryDirectory()
        let store = try await FileSecureStore.ephemeralUnprotected(directory: directory)

        let mnemonic = "abandon ability able about above absent absorb abstract absurd abuse"
        let seed = "deadbeef"

        try await store.saveMnemonic(mnemonic)
        try await store.saveSeed(seed)

        #expect(try await store.loadMnemonicString() == mnemonic)
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
        let store = try await FileSecureStore.ephemeralUnprotected(directory: directory)
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
        let store = try await FileSecureStore.ephemeralUnprotected(directory: directory)
        let fileURL = directory.appendingPathComponent("mnemonic.enc")

        try await store.saveMnemonic("abandon ability able about above absent absorb abstract absurd abuse")
        let originalCiphertext = try Data(contentsOf: fileURL)

        try await store.rotateMasterKey()

        let rotatedCiphertext = try Data(contentsOf: fileURL)
        #expect(originalCiphertext != rotatedCiphertext)
        #expect(try await store.loadMnemonicString() == "abandon ability able about above absent absorb abstract absurd abuse")
    }

    @Test("FileSecureStore fails closed without a password (Phase 3.5 regression)")
    func failsClosedWithoutPassword() async throws {
        let directory = try temporaryDirectory()
        // Empty password is rejected by the convenience initializer.
        await #expect(throws: SecureStoreError.self) {
            _ = try await FileSecureStore(directory: directory, password: "")
        }
        // Configuration with no password and no opt-in is rejected at bootstrap.
        let config = FileSecureStore.Configuration(directory: directory, password: nil)
        await #expect(throws: SecureStoreError.self) {
            _ = try await FileSecureStore(configuration: config)
        }
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

    @Test("Abandoned rotation (crash before commit) leaves the old key and data intact")
    func abandonedRotationRecovers() async throws {
        let directory = try temporaryDirectory()
        let configuration = FileSecureStore.Configuration(
            directory: directory,
            password: "strong-passphrase",
            pbkdfRounds: 25_000
        )
        let store = try await FileSecureStore(configuration: configuration)
        try await store.saveSeed("0123456789abcdef")

        // Simulate a crash mid-rotation, BEFORE the commit: a staged key container and a
        // staged (garbage) payload exist while the live key file is still authoritative.
        let stagedKey = directory.appendingPathComponent("secure_store_master_key.json.rotating")
        try Data("{\"bogus\": true}".utf8).write(to: stagedKey)
        let stagedSeed = directory.appendingPathComponent("seed.enc.rotating")
        try Data([0xDE, 0xAD]).write(to: stagedSeed)

        // Re-opening the store must discard the staged files and read the original data.
        let reopened = try await FileSecureStore(configuration: configuration)
        #expect(try await reopened.loadSeed() == "0123456789abcdef")
        #expect(!FileManager.default.fileExists(atPath: stagedKey.path))
        #expect(!FileManager.default.fileExists(atPath: stagedSeed.path))
    }

    @Test("Interrupted rotation after commit is completed on next open")
    func committedRotationCompletes() async throws {
        let directory = try temporaryDirectory()
        let configuration = FileSecureStore.Configuration(
            directory: directory,
            password: "strong-passphrase",
            pbkdfRounds: 25_000
        )
        let store = try await FileSecureStore(configuration: configuration)
        try await store.saveSeed("feedfacecafebeef")

        // Simulate the post-commit crash window: the live key is current, but a payload
        // still sits in its staged location (as if the final rename never ran). Staging a
        // copy of the live ciphertext models a same-key re-encryption for simplicity.
        let liveSeed = directory.appendingPathComponent("seed.enc")
        let stagedSeed = directory.appendingPathComponent("seed.enc.rotating")
        let ciphertext = try Data(contentsOf: liveSeed)
        try FileManager.default.removeItem(at: liveSeed)
        try ciphertext.write(to: stagedSeed)

        let reopened = try await FileSecureStore(configuration: configuration)
        #expect(try await reopened.loadSeed() == "feedfacecafebeef")
        #expect(!FileManager.default.fileExists(atPath: stagedSeed.path))
        #expect(FileManager.default.fileExists(atPath: liveSeed.path))
    }

    @Test("Supplying a password upgrades an ephemeral (plaintext-key) store in place")
    func ephemeralStoreUpgradesToPassword() async throws {
        let directory = try temporaryDirectory()
        let ephemeral = try await FileSecureStore.ephemeralUnprotected(directory: directory)
        try await ephemeral.saveSeed("00ff00ff00ff00ff")

        let keyURL = directory.appendingPathComponent("secure_store_master_key.json")
        struct Container: Decodable { let keyData: Data? }
        let before = try JSONDecoder().decode(Container.self, from: Data(contentsOf: keyURL))
        #expect(before.keyData != nil)

        // Re-open WITH a password: the store must stop trusting the raw on-disk key and
        // re-protect everything under the password instead of silently ignoring it.
        let upgraded = try await FileSecureStore(
            configuration: .init(directory: directory, password: "hunter2-but-long", pbkdfRounds: 25_000)
        )
        #expect(try await upgraded.loadSeed() == "00ff00ff00ff00ff")

        let after = try JSONDecoder().decode(Container.self, from: Data(contentsOf: keyURL))
        #expect(after.keyData == nil)
    }

    private func temporaryDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("cashu-secure-store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
#endif
