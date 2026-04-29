# Changelog

All notable changes to CoreCashu are tracked here. The format is loosely based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) once it tags 1.0.

CoreCashu is currently **pre-1.0**. Every change between now and the 1.0 tag may be
breaking; this file documents the consequential ones with migration notes.

## [Unreleased] — Phase 7 (API freeze + docs)

This entry covers the Phase 7 work tracked in [`/opus47.md`](../opus47.md).

### Breaking

- **Removed `@_exported import P256K`, `CryptoSwift`, `BigInt`** from `Sources/CoreCashu/CoreCashu.swift`.
  Consumers that referenced these dependency types through a transitive `import CoreCashu` must
  now declare those packages as their own dependencies and `import` them explicitly. See
  [`Docs/migration_guide.md`](Docs/migration_guide.md) for the per-type migration list.
- **Narrowed hex/string convenience extensions** in `Core/Extensions.swift` from `public` to
  `internal`. `Data(hexString:)`, `Data.hexString`, `Array<UInt8>.hexString`, `String.isValidHex`,
  `String.hexData`, `String.isNilOrEmpty`, and `Optional<String>.isNilOrEmpty` are no longer part
  of CoreCashu's public API. Consumers can use CryptoSwift's `Data.bytes` / `Array.toHexString()`
  or write their own utilities.
- **Optional NUT operations now throw `CashuError.unsupportedOperation`** when the connected mint
  doesn't advertise the capability in its `MintInfo`. Affected operations: `sendLocked`,
  `unlockP2PK`, `createHTLC`, `redeemHTLC`, `refundHTLC`, `checkHTLCStatus`. Required NUTs
  (01/02/03/04/05/06) are unaffected — the wallet refuses to initialise without them.
  `requireCapability(_:operation:)` is the public chokepoint integrators can use to add
  their own gates.

### Fixed

- **`NetworkRouter.execute` recorded breaker failures twice per 5xx response** (opus47.md §6.H).
  The breaker therefore opened at half the configured `failureThreshold` for HTTP-error paths.
  The inner status-code branch now only throws; the outer `catch` is the single failure-record
  site. Regression test in `Tests/CoreCashuTests/CircuitBreakerIntegrationTests.swift`.

### Tests

- 1047 Swift Testing tests pass (was 1043; +1 NetworkRouter regression, +3 capability-gating
  regressions for P2PK/HTLC/`requireCapability`).

## [Unreleased] — Phase 6 (Testing) — 2026-04-29

### Added

- **In-process `MockMint` test helper** (`Tests/CoreCashuTests/Helpers/MockMint.swift`) — a
  Networking adapter that handles every wallet-facing endpoint with real BDHKE crypto.
- **Wallet integration tests** covering mint→swap→send→receive→melt round-trips, double-spend
  rejection, NUT-04 disabled init refusal, and `checkProofStates`.
- **Live-mint P2PK and HTLC integration** (`MockMintLockedSpendingTests`) — closes the Phase 4
  deferred item.
- **CircuitBreaker behaviour audit** (`CircuitBreakerIntegrationTests`).

### Changed

- Every NUT-level service (`KeyExchangeService`, `MintService`, `MeltService`, `SwapService`,
  `MintInfoService`, `CheckStateService`, `RestoreSignatureService`, `KeysetManagementService`)
  now accepts an injected `networking: any Networking` parameter and forwards it to any
  sub-service. Previously the wallet's networking was reaching only the access-token
  middleware; integration tests against `MockMint` would otherwise hit `URLSession.shared`.
- `CashuEnvironment.current.routerDelegate` is swappable for tests via `setRouterDelegate(_:)` +
  `NetworkingPolicy.testPermissive`. `MockMint.installTestRouterDelegate()` installs the
  permissive policy automatically so concurrent test suites don't trip over the production
  rate limiter.

### Fixed

- **`NUTValidation.validateLightningInvoice` rejected every real BOLT11 invoice** — the Bech32
  alphabet check was applied to the entire string including the `lnbc` HRP (the Bech32 alphabet
  excludes `b`, `i`, `o`, `1`). Now correctly splits at the rightmost `1` separator and validates
  only the data part. Pre-existing bug surfaced when the MockMint started exercising the melt path.
- Replaced 15 `#expect(true)` smoke tests with concrete assertions or deletions; two cases in
  `FuzzTests/TokenSerializationFuzzTests` retain a non-asserting form intentionally because the
  contract is "doesn't trap" (commented).

## [Unreleased] — Phase 5 (Hardening + observability) — 2026-04-28

### Breaking

- **Strict concurrency now applies in release**, not only debug. `swiftLanguageModes: [.v6]`
  implies `-strict-concurrency=complete`; the previous `unsafeFlags(["-strict-concurrency=complete"], .when(.debug))`
  setting is gone. Consumers building CoreCashu in release will now see strict-concurrency
  diagnostics where before they were silently skipped.
- **`CashuError.networkFailure(NetworkErrorContext)` and `CashuError.wrappedFailure(message:underlying:)`
  added.** The legacy `.networkError(String)` case is retained for backwards compatibility, but
  new code should prefer the structured forms. `NetworkErrorContext` carries `httpStatus`,
  `responseBody` (capped at 4 KiB), and `underlying: any Error & Sendable`.

### Changed

- Removed all `print()` calls outside of intentional sinks (`ConsoleLogger`). `StructuredLogger.stdout`
  and `ConsoleMetricsClient` now write directly to `FileHandle.standardOutput`.
- `PerformanceMonitor.end` returns elapsed seconds (and exposes `elapsedMilliseconds()`) instead of
  printing.
- KDF parameters documented honestly in `Docs/security_assumptions.md` — BIP39 PBKDF2 is
  HMAC-SHA-512 / 2048 iterations / 64-byte output; `FileSecureStore` password-to-key PBKDF2 is
  HMAC-SHA-256 / 200_000 iterations / 32-byte salt.

### Fixed

- Vestigial `try` warning in `NUT00.swift:44` (P256K 0.23+ made `negation` non-throwing).

## [Unreleased] — Phase 4 (NUT completeness) — 2026-04-28

### Added

- **`CashuWallet.sendLocked(amount:to:locktime:refundPubkeys:requiredSigs:additionalPubkeys:signatureFlag:memo:)`**
  and **`unlockP2PK(token:privateKey:)`** in `HighLevelAPI/P2PKOperations.swift`. Multisig
  validation rejects empty pubkey list, out-of-range `requiredSigs`, and duplicate keys.
- **NUT-14 HTLC end-to-end** in `HighLevelAPI/HTLCOperations.swift` — `createHTLC`,
  `redeemHTLC`, `refundHTLC`, `checkHTLCStatus` now all plumb the witness through swap
  (the previous version generated the HTLC secret and then discarded it).
- The spec's official NUT-11 "valid signature" vector now cryptographically verifies.
- `SwapService.prepareSwapToSend(targetSecretFactory:)` — closure invoked once per *target*
  output. Target outputs use the locked secret string (with a fresh nonce per call); change
  outputs continue to use random secrets.

### Changed

- `refundHTLC` signs with BIP340 Schnorr (was ECDSA — wrong curve for NUT-14).
- `Docs/NUT_STATUS.md` — NUT-10 promoted to "complete" (schema flows through swap), NUT-11
  to "complete with public API," NUT-14 to "complete (HTLC end-to-end)".

## [Unreleased] — Phase 3 (Cross-platform crypto + networking) — 2026-04-28

### Breaking

- **`FileSecureStore(directory:password:)` requires a non-empty password.** The previous
  no-password mode silently wrote the AES key alongside the ciphertext. The opt-in form is now
  `FileSecureStore.ephemeralUnprotected(directory:)` for tests / sandboxed environments.
- **`CashuWallet`'s default `secureStore` is `nil` on non-Apple platforms.** Previously it would
  silently construct a no-password `FileSecureStore`. Linux consumers must inject one
  explicitly (a password-derived `FileSecureStore`, an OS-keyring backend, or an in-memory store
  for testing).
- **`Configuration.allowEphemeralUnprotectedKey: Bool`** field added (default `false`);
  `bootstrapKeyState` throws `passwordRequired` if neither a password nor explicit ephemeral
  consent is set.
- **`CashuError.invalidSpendingCondition(String)`** case added.

### Changed

- **All `import CryptoKit` removed from CoreCashu source.** New `Sources/CoreCashu/Cryptography/Hash.swift`
  module exposes `Hash.sha256(_:)`, `Hash.sha512(_:)`, and `Hash.hmacSHA512(key:data:)`, all
  CryptoSwift-backed. BDHKE, NUT-02 keyset ID derivation, NUT-11/14 message hashing, NUT-13
  BIP32/BIP39, NUT-20 mint-quote signing, and `Utils/BIP39.swift`'s PBKDF2 all use the wrapper.
  Validated against published SHA-256 / SHA-512 (NIST FIPS 180-4) and HMAC-SHA-512 (RFC 4231)
  vectors before swapping any callers — see `Tests/CoreCashuTests/HashTests.swift`.
- `URLSession` remains the HTTP default (works on Linux through `FoundationNetworking`).
- WebSocket protocol injection: Apple gets CashuKit's `URLSessionWebSocketTask` implementation;
  Linux consumers inject their own (e.g., `swift-nio` / `async-http-client`-backed).

## [Unreleased] — Phase 2 (Protocol correctness) — 2026-04-28

### Breaking — consensus-level fixes

- **NUT-11 P2PK signatures now use BIP340 Schnorr over secp256k1** (was Curve25519 — a consensus
  bug; locked tokens issued under the previous version cannot redeem against any real mint and
  were never on-protocol). Multisig now rejects duplicate signing pubkeys and credits each
  distinct signer at most once.
- **NUT-19 idempotency cache keys use real SHA-256** (was a single-byte modulo-256 sum). Anagrams
  no longer collide on the same key.
- **NUT-24 payment-request encoding routes through NUT-18** (`creqA...`) and NUT-00 V4 CBOR
  (`cashuB...` tokens). The previous `JSONEncoder().encode(token).base64EncodedString()` path is
  gone; consumers receiving the legacy wire format will see a decode failure.

### Added

- `Docs/NUT_STATUS.md` — per-NUT implementation / vector / capability-flag matrix.

### Tests

- Five new BIP340 / multisig regression tests for NUT-11.
- Two cache-hash regression tests for NUT-19.
- One legacy-format-rejected regression test for NUT-24.

### Deferred (capability flags must stay off)

- **NUT-21 (Clear auth / JWT)** — `validateSignature` only checks the `alg` field and that the
  signature isn't empty; JWKS isn't fetched, the signature isn't verified.
- **NUT-22 (Blind auth / BAT)** — uses `/v1/access` + `access_token` body field instead of
  `/v1/auth/blind/mint` + `Blind-auth: <token>` header; DLEQ proofs aren't verified at issuance.

## [Unreleased] — Phase 1 (Stop the bleeding) — 2026-04-28

### Breaking

- **`WalletConfiguration.init` is `throws`** — validates the mint URL up-front and exposes both
  `mintURL: String` and `mintURLValue: URL`. Internal sites use `mintURLValue` (no
  `URL(string:)!` anywhere downstream).
- **`P2PKSpendingCondition.multisig` throws** instead of `fatalError`-ing when the public-key
  list is empty.

### Changed

- Bumped dependencies: `swift-secp256k1 0.21.1 → 0.23.0`, `CryptoSwift 1.9 → 1.10`,
  `BigInt 5.6 → 5.7`, `SwiftCBOR 0.5 → 0.6`. P256K's API shifted between 0.21 and 0.23 —
  affected NUT-14, NUT-20 sites switched to the raw-bytes Schnorr overloads.
- `.github/workflows/ci.yml` added (macOS debug + macOS release-with-strict-concurrency +
  Linux job, Linux marked `continue-on-error` until Phase 3 lands).

### Fixed

- Five force-unwraps / `fatalError`s removed from production source (no `try!`, no `as!`, no
  `URL(string:)!` in non-test code).

## Pre-Phase-1

CoreCashu was untouched for several months prior to the work logged in `/opus47.md`. The 998
tests that passed at the start of Phase 1 were preserved through every subsequent phase; the
delta to the current 1047 reflects regression / vector / integration tests added per phase.
