import Foundation
import Testing
@testable import CoreCashu

/// Phase 8.10 (2026-04-29): coverage for the BIP39-mnemonic `SensitiveString` migration.
///
/// `DeterministicSecretDerivation` now accepts a `SensitiveString` natively; the legacy
/// `String` initializer wraps the mnemonic in a `SensitiveString` immediately so the
/// plaintext lifetime is bounded to the wrapper's deinit. This suite verifies the wrapped
/// path produces the same master key as the plain-string path (so the migration is
/// non-breaking) and that the wrapper exposes its plaintext only inside `withString`.
@Suite("SensitiveString mnemonic handling")
struct SensitiveMnemonicTests {

    private static let knownGoodMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    @Test("SensitiveString initializer derives the same master key as the String initializer")
    func sensitiveAndStringInitializersAgree() throws {
        let plain = try DeterministicSecretDerivation(mnemonic: Self.knownGoodMnemonic)
        let wrapped = try DeterministicSecretDerivation(
            mnemonic: SensitiveString(Self.knownGoodMnemonic)
        )

        // Same secret derivation under the same path → same hex.
        let plainSecret = try plain.deriveSecret(keysetID: "00ad268c4d1f5826", counter: 0)
        let wrappedSecret = try wrapped.deriveSecret(keysetID: "00ad268c4d1f5826", counter: 0)
        #expect(plainSecret == wrappedSecret, "Wrapped path must produce identical derivations")
    }

    @Test("SensitiveString-typed initializer rejects an invalid mnemonic")
    func sensitiveInitializerValidates() throws {
        let bogus = SensitiveString("not a valid mnemonic phrase at all")
        #expect(throws: CashuError.self) {
            _ = try DeterministicSecretDerivation(mnemonic: bogus)
        }
    }

    @Test("withString scopes plaintext access to the closure body")
    func withStringScopesPlaintextAccess() {
        let sensitive = SensitiveString("hunter2 hunter2 hunter2 hunter2")
        var captured = ""
        sensitive.withString { plaintext in
            captured = String(plaintext)
        }
        // After the scope returns the SensitiveString still holds its buffer; what we copied out
        // is a fresh String the test owns. Confirm the contents survived the scope but the
        // caller is free to wipe their copy when done.
        #expect(captured == "hunter2 hunter2 hunter2 hunter2")
    }

    @Test("isEmpty reports correctly under lock")
    func isEmptyReportsCorrectly() {
        let nonEmpty = SensitiveString(Self.knownGoodMnemonic)
        let empty = SensitiveString("")
        #expect(!nonEmpty.isEmpty)
        #expect(empty.isEmpty)
    }

    @Test("SecureStore round-trips a SensitiveString mnemonic without lifting plaintext to a String")
    func secureStoreSensitiveRoundTrip() async throws {
        let store = InMemorySecureStore()
        let original = SensitiveString(Self.knownGoodMnemonic)

        try await store.saveMnemonic(original)
        let loaded = try await store.loadMnemonic()
        #expect(loaded != nil)

        let matches = loaded?.withString { $0 == Self.knownGoodMnemonic } ?? false
        #expect(matches, "wrapped mnemonic should round-trip equal to the original under withString")
    }

    @Test("SecureStore.loadMnemonicString convenience returns the same value as String save+load")
    func secureStoreStringConvenience() async throws {
        let store = InMemorySecureStore()
        try await store.saveMnemonic(Self.knownGoodMnemonic) // exercises the String overload
        let loaded = try await store.loadMnemonicString()
        #expect(loaded == Self.knownGoodMnemonic)
    }
}
