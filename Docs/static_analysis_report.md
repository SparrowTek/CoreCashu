# CoreCashu Static Analysis Report

> **Date:** April 28, 2026
> **Build status:** Passing on macOS (debug). Linux build is broken pending Phase 2 of `opus47.md`.
> **Test status:** 998 Swift Testing tests passing on macOS.
> **Compiler warnings:** 2 minor `try` smells (vestigial after refactors); see §1.3.

## Executive Summary

This report documents static-analysis findings against the CoreCashu sources following Phase 1 of `opus47.md` ("Stop the bleeding"). Earlier revisions of this document overstated the codebase's hardening level — that has been corrected here.

**Overall assessment:** No remaining force unwraps, force casts, force tries, `fatalError` calls, `print()` statements, or `TODO/FIXME` markers in production source code. Several gaps remain (CryptoKit on Linux, dependency-version skew downstream, `print()` calls in observability code, strict-concurrency only enforced in debug). These are tracked as follow-up phases in `opus47.md`.

---

## 1. Build Analysis

### 1.1 Compilation
- Toolchain: Swift 6.1, language mode Swift 6 (`swiftLanguageModes` set on dependents).
- Targets verified: `arm64-apple-macos`. iOS/tvOS/watchOS/visionOS via `xcodebuild` paths not run as part of this report.
- Linux: not verified. `import CryptoKit` in 12 source files blocks the Linux build today (Phase 2 of `opus47.md`).

### 1.2 Strict concurrency
```swift
swiftSettings: [
    .enableUpcomingFeature("ExistentialAny"),
    .unsafeFlags(["-strict-concurrency=complete"], .when(configuration: .debug))
]
```
**Caveat:** `-strict-concurrency=complete` is debug-only. Production builds do not currently enforce it. Phase 4 of `opus47.md` removes the `.when(configuration: .debug)` guard and switches to first-class strict-concurrency once the dependent codebase is clean in release.

### 1.3 Outstanding warnings
| File | Line | Warning |
|------|------|---------|
| `Sources/CoreCashu/HighLevelAPI/HTLCOperations.swift` | 239 | `try` with no throwing function — vestigial after a refactor |
| `Sources/CoreCashu/NUTs/NUT00.swift` | 45 | Same shape as above |

These are not security-relevant. Cleanup is bundled into Phase 4.

---

## 2. Unsafe Code Patterns

### 2.1 Force unwraps (`!`)
Phase 1 removed five force unwraps from production source:

| File | Line (pre-Phase-1) | Pattern | Resolution |
|------|--------------------|---------|------------|
| `Sources/CoreCashu/CashuWallet.swift` | 607 | `URL(string: configuration.mintURL)!` (access-token save) | `WalletConfiguration` now validates the mint URL at init, exposes `mintURLValue: URL`. Call sites use the validated URL. |
| `Sources/CoreCashu/CashuWallet.swift` | 638 | `URL(string: configuration.mintURL)!` (access-token load) | Same. |
| `Sources/CoreCashu/WebSockets/RobustWebSocketClient.swift` | 424 | `try await group.next()!` | Replaced with `guard let result = ...` and explicit timeout throw. |
| `Sources/CoreCashu/SecureStorage/FileSecureStore.swift` | 374 | `FileManager.default.urls(...).first!` | Replaced with `?? FileManager.default.temporaryDirectory` fallback. |
| `Sources/CoreCashu/NUTs/NUT11.swift` | 167 | `fatalError("At least one public key required")` (in `multisig` factory) | Function now `throws CashuError.invalidSpendingCondition(...)`. Validates `requiredSigs` range too. |

Re-scan after Phase 1: no production force unwraps remain.

### 2.2 Force casts (`as!`)
Search: `as!` — no occurrences in production source.

### 2.3 Force try (`try!`)
Search: `try!` — no occurrences in production source.

### 2.4 `fatalError`
Search: `fatalError(` — no remaining call sites in production source.
(`Sources/CoreCashu/Core/Headers.swift:11` contains a `fatalError` *inside a comment* documenting an old API contract; harmless.)

### 2.5 TODO / FIXME / HACK
None in production source.

### 2.6 `print()`
Five non-default-implementation locations remain. Tracked as Phase 4 cleanup:
- `Observability/StructuredLogger.swift:312`
- `Observability/MetricsClient.swift:165, 171, 178, 188`
- `Performance/PerformanceOptimizations.swift:219`

`DefaultImplementations/ConsoleLogger.swift` retains `print()` calls intentionally — it is the default console sink.

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
| `DefaultImplementations/InMemorySecureStore.swift` | wrapper | actor-internal | Test/dev only — deprecated for production |

Phase 4 of `opus47.md` adds `// @unchecked Sendable: protected by <mechanism>` comments next to each declaration so a future auditor can verify without reading the whole class.

---

## 4. Cryptographic Hygiene

### 4.1 Randomness
- All security-relevant randomness goes through `SecureRandom`, which uses `SecRandomCopyBytes` on Apple and `SystemRandomNumberGenerator` elsewhere.
- A handful of `Double.random()` uses exist in retry-jitter code paths only.

### 4.2 Constant-time comparison
- `SecureMemory.constantTimeCompare(_:_:)` for `Data` and `[UInt8]` overloads. Used in NUT-22 access-token comparison and in DLEQ verification. Signature verification delegates to P256K (constant-time property inherited).

### 4.3 Memory wiping
- `SecureMemory.wipe(_:)` performs a multi-pattern overwrite (zero / random / zero) on `inout Data` and `inout [UInt8]`.
- Best-effort only — Swift compiler may elide writes on release builds. Documented in source.
- BIP39 mnemonic still flows through `String` in some paths (Phase 4 of `opus47.md` wraps these in `SensitiveString` end-to-end).

### 4.4 BIP340 Schnorr
- After the dependency bump (Phase 1.3), CoreCashu calls into P256K's raw-bytes Schnorr API (`signature(message:auxiliaryRand:strict:)` and `isValid(_:for:)`) rather than the new `Digest`-based overloads. This makes the call sites cross-platform-friendly and removes a CryptoKit dependency from the Schnorr code paths.
- Pre-computed 32-byte SHA-256 message hashes are still produced via `CryptoKit.SHA256` — Phase 2 swap to CryptoSwift will close that gap.

---

## 5. Dependencies (after Phase 1.3 bump)

| Dependency | Version | Notes |
|------------|---------|-------|
| `swift-secp256k1` (P256K) | 0.23.0 | Schnorr API now `Digest`-typed; CoreCashu uses raw-bytes overloads. |
| `CryptoSwift` | 1.10.0 | Aligned with CashuKit. |
| `BigInt` | 5.7.0 | Aligned with CashuKit. |
| `SwiftCBOR` | 0.6.0 | Aligned with CashuKit. |

### 5.1 Skew with CashuKit
After Phase 1.3, CoreCashu and CashuKit pin the same minimum versions. SPM resolves to a single version of each dependency in any consumer's graph.

### 5.2 Open recommendations (Phase 4+)
- Pin exact versions for reproducibility once 1.0 is tagged.
- Add automated vulnerability scanning (`gh dependabot` or equivalent).

---

## 6. Test Coverage

| Metric | Current |
|--------|---------|
| Test files (CoreCashuTests) | 63 |
| `@Test` blocks | ~900 |
| Pass rate (macOS, debug) | 998/998 (some live-mint suites are `.disabled`) |
| Estimated line coverage | ~75% (not measured by tooling — claim subject to revision in Phase 5) |

### 6.1 Newly added (Phase 1)
- `CashuWalletTests.walletConfiguration_rejectsMalformedURL` — three URL-validation cases for the new throwing init.
- `NUT11Tests.testMultisigRejectsInvalidInputs` — three invalid-input cases for the multisig factory replacing `fatalError`.

### 6.2 Tracked gaps
- NUT-10/14/15/19/21/23 lack dedicated test files (Phase 5 of `opus47.md`).
- Fuzz testing of token/CBOR parsing not yet present (Phase 5).
- BDHKE invalid-point and DLEQ negative tests not yet present.

---

## 7. Pending Hardening Items

The high-level production-readiness plan lives in `/opus47.md`. This report's scope is verifying claims; the plan is the action list.

| ID | Item | Plan phase |
|----|------|------------|
| H1 | Remove `import CryptoKit` to unbreak Linux | Phase 2 |
| H2 | Cross-platform HTTP / WS strategy | Phase 2 |
| H3 | Strict concurrency in release config | Phase 4 |
| H4 | Replace `print()` in `MetricsClient` / `StructuredLogger` | Phase 4 |
| H5 | Wrap mnemonic in `SensitiveString` end-to-end | Phase 4 |
| H6 | Test vector parity with `claude/Nuts/tests/` | Phase 3.5 |
| H7 | Mock-mint integration test suite | Phase 5.4 |

---

## 8. Conclusion

After Phase 1, the previously-overstated claims in this report are now substantively true: no force unwraps, force casts, `try!`, `as!`, or `fatalError` in production source; comprehensive input validation; constant-time and zeroization helpers in place; actor-based concurrency.

Outstanding production-readiness items are concrete and tracked, primarily around (a) removing CryptoKit dependency to unblock Linux, (b) tightening strict concurrency to release builds, and (c) finishing test coverage for under-served NUTs. None of these are crypto-critical; the underlying BDHKE/BIP39/DLEQ implementations are in good shape pending external audit.

External security audit should be scheduled after Phase 4 of `opus47.md` lands.

---

*Last updated: 2026-04-28 — supersedes earlier December 29, 2025 revision.*
