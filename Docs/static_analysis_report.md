# CoreCashu Static Analysis Report

> **Date:** April 29, 2026 (post Phase 7 of `/opus47.md`)
> **Build status:** Clean on macOS in **debug and release**. Linux job is `continue-on-error` in CI; verify locally before relying on it.
> **Test status:** 1047 Swift Testing tests passing on macOS.
> **Compiler warnings:** None in production source after the Phase 5.6 vestigial-`try` cleanup.

## Executive Summary

This report documents static-analysis findings against the CoreCashu sources after Phases 1–7 of `/opus47.md`. It supersedes prior revisions of this file.

**Overall assessment:** No remaining force unwraps, force casts, force tries, `fatalError` calls, `print()` statements, or `TODO/FIXME` markers in production source. Strict concurrency is enforced in **debug and release** via `swiftLanguageModes: [.v6]`. The dependency surface is decoupled from CoreCashu's public API — `@_exported` re-exports of `P256K`, `CryptoSwift`, and `BigInt` were removed in Phase 7.1.

Two protocol-correctness gaps remain — NUT-21 (JWT verification is a stub) and NUT-22 (endpoint and header shape don't match spec). Their `MintFeatureCapabilities` flags must remain off until the corresponding fixes land. See `Docs/NUT_STATUS.md`.

---

## 1. Build Analysis

### 1.1 Compilation
- Toolchain: Swift 6.1, language mode Swift 6 (`swiftLanguageModes: [.v6]` set).
- Targets verified: `arm64-apple-macos`, `arm64-apple-ios-simulator` (via `xcodebuild`).
- Linux: `swift build` succeeds in principle (CryptoKit removed in Phase 3.1); the GitHub Actions Linux job remains `continue-on-error` until end-to-end verification.

### 1.2 Strict concurrency
```swift
swiftSettings: [
    .enableUpcomingFeature("ExistentialAny")
],
swiftLanguageModes: [.v6]
```
Swift 6 mode implies `-strict-concurrency=complete` in **both** debug and release. The earlier `unsafeFlags(["-strict-concurrency=complete"], .when(.debug))` is gone (Phase 5.1).

### 1.3 Outstanding warnings
None. The two vestigial-`try` smells in `NUT00.swift:44` and `HTLCOperations.swift:239` were cleaned up in Phase 5.6 / Phase 4.C.

---

## 2. Unsafe Code Patterns

| Pattern | Production source | Notes |
|---------|------------------:|-------|
| Force unwraps (`!`) | 0 | Removed in Phase 1.1; `WalletConfiguration` validates the mint URL once and exposes `mintURLValue: URL`. |
| Force casts (`as!`) | 0 | |
| Force try (`try!`) | 0 | |
| `fatalError(` | 0 | Phase 1.1 replaced the only call site (`P2PKSpendingCondition.multisig`) with throwing validation. |
| `TODO` / `FIXME` / `HACK` | 0 | |
| `print(` | 0 outside intentional sinks | `DefaultImplementations/ConsoleLogger.swift` retains `print()` *intentionally* (default console sink). `StructuredLogger` and `ConsoleMetricsClient` write to `FileHandle.standardOutput` directly (Phase 5.2). |

---

## 3. `@unchecked Sendable` Audit

| File | Type | Synchronization | Status |
|------|------|-----------------|--------|
| `Security/SecureMemory.swift` | `SensitiveData` | `NSLock` | Justified |
| `Security/SecureMemory.swift` | `SensitiveString` | `NSLock` | Justified |
| `Utils/CryptoLock.swift` | `CryptoLock` | `NSLock` | Justified |
| `Utils/SecureRandom.swift` | `GeneratorBox` | `NSLock` | Justified |
| `Observability/StructuredLogger.swift` | `StructuredLogger` | concurrent `DispatchQueue` + barrier writes | Justified |
| `Observability/OSLogger.swift` | `OSLogger` | concurrent `DispatchQueue` + barrier writes | Justified |
| `DefaultImplementations/InMemorySecureStore.swift` | wrapper | actor-internal | Test/dev only |

---

## 4. Cryptographic Hygiene

### 4.1 Randomness
- All security-relevant randomness goes through `SecureRandom`, which uses `SecRandomCopyBytes` on Apple and `SystemRandomNumberGenerator` elsewhere.
- `Double.random()` is used only in retry-jitter code paths.

### 4.2 Constant-time comparison
- `SecureMemory.constantTimeCompare(_:_:)` for `Data` and `[UInt8]`. Used for NUT-22 access-token comparison and DLEQ verification. Signature verification delegates to P256K (constant-time property inherited).

### 4.3 Memory wiping
- `SecureMemory.wipe(_:)` performs multi-pattern overwrite (zero / random / zero) on `inout Data` / `inout [UInt8]`.
- BIP39 mnemonic still flows through `String` in some paths. End-to-end `SensitiveString` wrapping remains tracked as a Phase 7.6 follow-up item — non-trivial because Swift `String` may intern.

### 4.4 BIP340 Schnorr (NUT-11 P2PK, NUT-14 HTLC, NUT-20 mint quotes)
- Phase 2.1 fixed the consensus bug (was `Curve25519.Signing.PublicKey` — wrong curve). All BIP340 paths now go through `NUT20SignatureManager.signMessage` / `verifySignature`, which call P256K's raw-bytes `signature(message:auxiliaryRand:strict:)` and `isValid(_:for:)` overloads.
- The spec's official NUT-11 "valid signature" vector verifies under this path (`Tests/CoreCashuTests/NUT11Tests.swift`).

### 4.5 Hashing
- All SHA-256 / SHA-512 / HMAC-SHA-512 goes through `Sources/CoreCashu/Cryptography/Hash.swift` (CryptoSwift-backed). CryptoKit is no longer imported anywhere in CoreCashu source. NIST FIPS 180-4 and RFC 4231 vectors verified — `Tests/CoreCashuTests/HashTests.swift`.

### 4.6 KDF
- BIP39 PBKDF2 = HMAC-SHA-512 / 2048 iterations / 64-byte output (verified against BIP39 vectors).
- `FileSecureStore` password-to-key PBKDF2 = HMAC-SHA-256 / 200_000 iterations / 32-byte salt.
- Both implemented via `CryptoSwift.PKCS5.PBKDF2`.

---

## 5. Dependencies

| Dependency | Version | Used for |
|------------|---------|----------|
| `swift-secp256k1` (P256K) | 0.23.0 | secp256k1 + BIP340 Schnorr |
| `CryptoSwift` | 1.10.0 | SHA-256/512, HMAC, PBKDF2, AES-GCM (FileSecureStore) |
| `BigInt` | 5.7.0 | NUT-12 DLEQ challenge math |
| `SwiftCBOR` | 0.6.0 | NUT-00 V4 token codec |

These versions are aligned with CashuKit. Post-Phase-7.1, CoreCashu does not re-export them via `@_exported import` — consumers depending on these types directly must declare the dependencies in their own `Package.swift`.

---

## 6. Test Coverage

| Metric | Current |
|--------|---------|
| Test files (CoreCashuTests) | 64+ |
| `@Test` blocks | 1047 |
| Pass rate (macOS, debug + release) | 1047/1047 |
| Live-mint integration | In-process `MockMint` (Phase 6) — covers mint→swap→send→receive→melt, P2PK round-trip, HTLC round-trip, double-spend rejection, capability gating |
| Spec-vector tests | NUT-00 BDHKE, NUT-02, NUT-11 (incl. spec valid/invalid vectors), NUT-12 DLEQ, NUT-13 BIP32/BIP39, NUT-18 |

### 6.1 Tracked gaps
- NUT-15 (MPP) integration tests — type-only.
- NUT-17 reconnect-and-resume integration test — MockMint is HTTP-only.
- NUT-21 / NUT-22 spec-vector tests — blocked on the Phase 2.3 / 2.4 protocol-correctness work.
- Deeper CashuKit unit tests (BiometricAuthManager, BackgroundTaskManager, NetworkMonitor, AppleWebSocketClient).
- End-to-end `SensitiveString` for the BIP39 mnemonic.

---

## 7. Pending Hardening Items

| ID | Item | Plan phase |
|----|------|------------|
| H1 | NUT-21 (Clear auth / JWT) — implement real JWKS fetch + ES256/RS256 signature verification | opus47.md §2.3 |
| H2 | NUT-22 (Blind auth / BAT) — switch to `/v1/auth/blind/mint` + `Blind-auth: <token>` header, verify DLEQ at issuance | opus47.md §2.4 |
| H3 | End-to-end `SensitiveString` for BIP39 mnemonic | opus47.md §7.6 |
| H4 | Linux CI job promoted from `continue-on-error` to required | opus47.md §1.4 / §3 |
| H5 | Public BDHKE primitives (`hashToCurve`, `addPoints`, etc.) namespaced under `BDHKE` enum or moved to a separate `CoreCashuLowLevel` product target | opus47.md §7.2 (deferred — 54 call sites) |

---

## 8. Conclusion

CoreCashu has worked through the full Phase 1–7 production-readiness plan in `/opus47.md`. The protocol is correct on the wire for every NUT advertised in `MintFeatureCapabilities`, the public API is narrowed and capability-gated, strict concurrency is enforced in debug and release, and 1047 tests pass against an in-process MockMint that doesn't require a live mint to verify behaviour.

The two material gaps blocking advertised support for NUT-21 and NUT-22 are tracked above. The package is otherwise ready for external security audit.
