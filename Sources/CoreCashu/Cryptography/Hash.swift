import Foundation
import CryptoSwift

/// Cross-platform hash and MAC primitives used by CoreCashu.
///
/// CoreCashu must run on Apple platforms and on Linux. Apple's `CryptoKit` is not available on
/// Linux, so this module wraps the project's existing `CryptoSwift` dependency and exposes the
/// minimum surface CoreCashu needs:
///
/// - `Hash.sha256(_:)` and `Hash.sha512(_:)` — one-shot hashes that return `Data`.
/// - `Hash.hmacSHA512(key:data:)` — HMAC used by NUT-13 BIP32 derivation and BIP39 seed mixing.
///
/// PBKDF2 callers use `CryptoSwift.PKCS5.PBKDF2` directly — no further wrapper is needed.
///
/// This is the single chokepoint. If profiling later shows CryptoKit is meaningfully faster on
/// Apple, this file is the only place to add a `#if canImport(CryptoKit)` fast path.
public enum Hash {

    // MARK: - One-shot SHA-2

    /// SHA-256 digest of `data`. Returns the 32-byte digest as `Data`.
    public static func sha256(_ data: Data) -> Data {
        Data(data.sha256())
    }

    /// SHA-256 digest of a byte array. Returns the 32-byte digest as `Data`.
    public static func sha256(_ bytes: [UInt8]) -> Data {
        Data(bytes.sha256())
    }

    /// SHA-512 digest of `data`. Returns the 64-byte digest as `Data`.
    public static func sha512(_ data: Data) -> Data {
        Data(data.sha512())
    }

    /// SHA-512 digest of a byte array. Returns the 64-byte digest as `Data`.
    public static func sha512(_ bytes: [UInt8]) -> Data {
        Data(bytes.sha512())
    }

    // MARK: - HMAC

    /// HMAC-SHA-512 of `data` keyed by `key`. Returns the 64-byte tag as `Data`.
    public static func hmacSHA512(key: Data, data: Data) -> Data {
        // Use the module-qualified name because `HMAC` also exists in CryptoKit on Apple
        // platforms (re-exported through CoreCashu's `@_exported import` chain) and the
        // unqualified spelling would resolve ambiguously.
        do {
            let mac = CryptoSwift.HMAC(
                key: Array(key),
                variant: CryptoSwift.HMAC.Variant.sha2(.sha512)
            )
            return Data(try mac.authenticate(Array(data)))
        } catch {
            preconditionFailure("HMAC-SHA512 setup failed: \(error)")
        }
    }
}
