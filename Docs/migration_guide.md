# CoreCashu Migration Guide

This document covers every breaking change between the unreleased pre-1.0 builds of
CoreCashu, organised so you can read it top-to-bottom and update a consumer in one
pass. The corresponding diff log lives in [`/CHANGELOG.md`](../CHANGELOG.md); the
phase-by-phase rationale lives in [`/opus47.md`](../../opus47.md).

There are no external 1.0 consumers yet, so this guide also serves as the contract
for future migrations: every breaking change here should be visible to a reader
without reading the full plan.

---

## TL;DR — what to change

If you're consuming CoreCashu from another package or app:

1. **Add explicit `import` lines** for any of `P256K`, `CryptoSwift`, or `BigInt` types
   you reference. They are no longer transitively re-exported.
2. **Wrap `WalletConfiguration(...)` in `try`** — the initializer is throwing and
   validates the mint URL.
3. **Catch `CashuError.unsupportedOperation`** when calling optional NUTs (P2PK, HTLC,
   state check, restore). The wallet now refuses to expose them when the connected
   mint doesn't advertise the capability.
4. **Provide a password (or an explicit ephemeral factory) to `FileSecureStore`** if
   you use it. The no-password convenience initializer is gone.
5. **Stop relying on `NUT-11` / `NUT-22` / `NUT-24` legacy wire formats** —
   pre-Phase-2 P2PK tokens, BAT requests, and `cashuB` payment payloads will not
   round-trip against the post-Phase-2 implementation.

If you're building inside the CoreCashu repo: see the per-phase notes below.

---

## 1 — `WalletConfiguration` is throwing (Phase 1.1)

Before:
```swift
let config = WalletConfiguration(
    mintURL: "https://mint.example.com",
    unit: .sat,
    derivationPath: "m/129372'/0'/0'",
    maxRetries: 3
)
let wallet = await CashuWallet(configuration: config)
```

After:
```swift
let config = try WalletConfiguration(
    mintURL: "https://mint.example.com",
    unit: "sat"
)
let wallet = await CashuWallet(configuration: config)
```

**Why:** The previous version stored `mintURL` as `String` and re-parsed it with
`URL(string:)!` at every call site. The throwing init validates the URL once, exposes
both `mintURL: String` (for serialization) and `mintURLValue: URL` (for use), and
guarantees `URL(string:)!` does not appear anywhere downstream.

**`CashuError.invalidMintURL`** is the thrown case. Catch it (or surface it through
your app's error funnel) and prompt the user to re-enter a valid URL.

The `derivationPath` and `maxRetries` parameters have not been part of the public
init for some time; if your code references them you're tracking an old build and
will need to consult the current `WalletConfiguration` definition.

---

## 2 — NUT-11 P2PK consensus fix (Phase 2.1)

**Tokens you locked under any pre-Phase-2 build cannot be redeemed.**

Before, `P2PKSignatureValidator` validated witnesses with `Curve25519.Signing.PublicKey`.
Cashu P2PK uses BIP340 Schnorr over secp256k1. No real mint accepts a Curve25519
witness, so any P2PK token the previous version produced was unredeemable in
practice; the bug was masked because all of our tests verified the wrong curve too.

If you have:

- **Test fixtures** that pre-compute P2PK witnesses, regenerate them under the new
  Schnorr path. The spec's official "valid signature" vector now passes — see
  `Tests/CoreCashuTests/NUT11Tests.swift`.
- **Stored tokens** in a development database, throw them away. There were no
  external production users.
- **Calls to `P2PKSpendingCondition.multisig`**, note that the factory now `throws`
  (was `fatalError`-ing on empty pubkey lists) and rejects duplicate signing keys
  and out-of-range `requiredSigs`.

The high-level `CashuWallet.sendLocked(...)` and `unlockP2PK(...)` APIs (added in
Phase 4.A) wrap the corrected Schnorr path. Prefer them over the lower-level
spending-condition types.

---

## 3 — NUT-19 cache hash (Phase 2.2)

If you implemented an idempotent retry helper that compared CoreCashu cache keys to
your own derived hashes, your derivation must move from "byte sum modulo 256" to
"real SHA-256 over canonical request bytes." The previous fallback `simpleHash` (a
`Swift.hashValue` wrapper) was not stable across runs.

This shouldn't affect on-disk state or wire format — the cache is in-memory.

---

## 4 — NUT-22 endpoint and shape (Phase 2.4 deferred — capability flag stays off)

**Phase 2.4 is not yet implemented.** The current code uses `/v1/access` with an
`access_token` body field; the spec uses `/v1/auth/blind/mint` with a
`Blind-auth: <token>` header and one BAT consumed per protected request, plus DLEQ
verification at issuance. Until Phase 2.4 lands, the NUT-22 capability flag is off
and the wallet refuses to talk to mints that require blind auth.

**Migration impact:** none yet — the capability is gated. When Phase 2.4 lands, this
guide will document the actual move.

If you have NUT-22-specific code paths in your consumer, treat them as on hold.

---

## 5 — NUT-24 payment-request encoding (Phase 2.5)

If you have a back-end that produces `cashuB` payment-request payloads or an
`X-Cashu` header for HTTP 402 responses:

- **Before:** `JSONEncoder().encode(token).base64EncodedString()` prefixed with `cashuB`.
- **After:** `CashuTokenUtils.serializeTokenV4(token)` for the embedded token, and
  `PaymentRequestEncoder.encode(...)` (the NUT-18 `creqA...` codec) for the request
  envelope.

The new wire format is what real wallets accept; the legacy format is silently
rejected at decode. There's a regression test in `Tests/CoreCashuTests/NUT24Tests.swift`
that verifies the legacy format no longer decodes.

If you cached the old payload anywhere, regenerate.

---

## 6 — Cross-platform crypto (Phase 3.1)

If you imported `CryptoKit` directly to use the same hash primitives as CoreCashu, switch to:

```swift
import CoreCashu

let digest = Hash.sha256(payload)
let mac = Hash.hmacSHA512(key: macKey, data: payload)
```

`Hash` is exposed under CoreCashu's public API. CoreCashu source itself no longer
imports `CryptoKit` anywhere. PBKDF2 callers use `CryptoSwift.PKCS5.PBKDF2` directly
(BIP39 = HMAC-SHA-512 / 2048 iterations / 64-byte output; FileSecureStore =
HMAC-SHA-256 / 200_000 iterations / 32-byte salt — both verified against published
vectors in `Tests/CoreCashuTests/HashTests.swift`).

---

## 7 — `FileSecureStore` no-password mode is gone (Phase 3.5)

Before:
```swift
let store = try await FileSecureStore(directory: keystoreDir)  // wrote AES key into the same file as ciphertext
```

After:
```swift
// Production: provide a password.
let store = try await FileSecureStore(directory: keystoreDir, password: passphrase)

// Tests / sandboxes that explicitly opt in:
let store = try FileSecureStore.ephemeralUnprotected(directory: keystoreDir)
```

`bootstrapKeyState` throws `SecureStoreError.passwordRequired` if neither a password
nor `Configuration.allowEphemeralUnprotectedKey: true` is set. The `default()`
static factory was removed.

**Why:** the previous mode wrote the AES-GCM key inside the same file as the
encrypted payload. A `cp -r` of the storage directory exfiltrated both halves —
that's recoverable obfuscation, not encryption.

`CashuWallet`'s default `secureStore` on non-Apple platforms is now `nil` — Linux
consumers must inject one explicitly (a password-derived `FileSecureStore`, an
OS-keyring backend, or `InMemorySecureStore` for testing).

---

## 8 — Strict concurrency in release (Phase 5.1)

If you build CoreCashu in release configuration, you may now see strict-concurrency
diagnostics that were previously silently skipped. Resolve them by adding `Sendable`
conformance, marking globals with isolation, or wrapping mutable shared state in an
actor.

There is no opt-out — the package declares `swiftLanguageModes: [.v6]` which implies
`-strict-concurrency=complete` for both configurations.

---

## 9 — `CashuError.networkFailure` and `wrappedFailure` (Phase 5.4)

Two new structured `CashuError` cases:

```swift
case networkFailure(NetworkErrorContext)
case wrappedFailure(message: String, underlying: any Error & Sendable)
```

`NetworkErrorContext` carries `httpStatus: Int?`, `responseBody: String?` (capped at
4 KiB), and `underlying: (any Error & Sendable)?`. The legacy `.networkError(String)`
case is retained so existing pattern matches don't need to change immediately, but
new code should prefer the structured forms.

`CashuError.isRetryable` was extended: `networkFailure` retries on 5xx/429 and on
missing-status (DNS/TLS/timeout — request never landed).

---

## 10 — `@_exported` removal (Phase 7.1)

Before, `Sources/CoreCashu/CoreCashu.swift` had:

```swift
@_exported import P256K
@_exported import CryptoSwift
@_exported import BigInt
```

so `import CoreCashu` transitively imported the dependencies' public symbols. They
are gone.

If your consumer code references types like `P256K.KeyAgreement.PrivateKey`,
`P256K.Signing.PublicKey`, `CryptoSwift.PKCS5.PBKDF2`, `BigUInt`, etc., you must:

1. Add the relevant package as a dependency in your `Package.swift`:

   ```swift
   dependencies: [
       .package(url: "https://github.com/SparrowTek/CoreCashu", from: "1.0.0"),
       .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", from: "0.23.0"),
       // ... only the ones you actually use:
       .package(url: "https://github.com/krzyzanowskim/CryptoSwift", from: "1.10.0"),
       .package(url: "https://github.com/attaswift/BigInt", from: "5.7.0"),
   ]
   ```

   And add them to your target's `dependencies:`.

2. Add explicit `import` lines in the source files that use them.

**Why:** `@_exported` made every public type in those three dependencies part of
CoreCashu's public API contract. A minor version bump in any of them could be a
breaking change in CoreCashu — and the API surface was unboundedly large. Removing
the re-exports makes CoreCashu's SemVer match its own source.

---

## 11 — Hex/string convenience extensions narrowed (Phase 7.1)

Before:
```swift
import CoreCashu
let bytes = Data(hexString: "deadbeef")
print(bytes?.hexString)
```

After (these are now `internal`):
```swift
// Use CryptoSwift's API:
import CryptoSwift
let bytes = Array<UInt8>(hex: "deadbeef")
print(bytes.toHexString())

// Or write your own — the helpers are 5 lines each.
```

`Data.hexString`, `Data(hexString:)`, `Array<UInt8>.hexString`, `String.isValidHex`,
`String.hexData`, `String.isNilOrEmpty`, and `Optional<String>.isNilOrEmpty` are
no longer part of CoreCashu's public API.

---

## 12 — Capability gating at the public API (Phase 7.3)

The wallet now refuses to expose optional NUTs when the connected mint doesn't
advertise the capability:

```swift
do {
    let token = try await wallet.sendLocked(amount: 100, to: pubkey)
} catch let error as CashuError {
    if case .unsupportedOperation(let message) = error {
        // Mint doesn't support NUT-11. Fall back to plain `send`, surface a clear
        // message, etc.
        showAlert("This mint doesn't support locked tokens: \(message)")
    }
}
```

Affected operations:

- `sendLocked`, `unlockP2PK` — gated on `.p2pk` (NUT-11)
- `createHTLC`, `redeemHTLC`, `refundHTLC`, `checkHTLCStatus` — gated on `.htlc` (NUT-14)
- `checkProofStates` — already gated on `.stateCheck` (NUT-07)
- `restoreFromSeed` — already gated on `.restore` (NUT-09)

`CashuWallet.requireCapability(_:operation:)` is the public chokepoint integrators
can use for their own gates. Required NUTs (`01`/`02`/`03`/`04`/`05`/`06`) are
unaffected — the wallet refuses to initialise without them, which is enforced
earlier in the lifecycle.

---

## Sequencing notes

If you're upgrading through several pre-1.0 builds at once:

1. Address §1 (throwing init) first — it surfaces compile errors at the call site.
2. Address §10 (`@_exported`) next — same reason.
3. Address §7 (`FileSecureStore`) — it surfaces at runtime, not compile time, so
   easy to miss.
4. Address §12 (capability gating) — surfaces at runtime when talking to mints that
   don't advertise a capability.
5. The other items (§2 / §4 / §5 / §6 / §11) are point fixes that won't compound.

After upgrading, re-run any P2PK fixture-generation scripts (§2) and regenerate any
cached `cashuB` payment payloads (§5).
