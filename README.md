# CoreCashu

> **PRE-1.0 / BETA** — API freeze in progress.
>
> CoreCashu has completed phases 1–7 of the production-readiness plan in `/opus47.md`.
> The protocol is correct on the wire (post-Phase-2 fixes for NUT-11 curve, NUT-19
> hashing, NUT-24 routing), Linux is a first-class target (Phase 3), HTLC and P2PK
> wallet APIs are end-to-end (Phase 4), strict concurrency is enforced in debug and
> release (Phase 5), 1047 Swift Testing tests pass against an in-process MockMint
> (Phase 6), and the public API has been narrowed (Phase 7).
>
> Two NUTs are explicitly **not safe to advertise** until follow-on work lands —
> NUT-21 (JWT verification is a stub) and NUT-22 (endpoint and header shape don't
> match the spec). Their capability flags must remain off. See
> [`Docs/NUT_STATUS.md`](Docs/NUT_STATUS.md).
>
> **Pending external security audit before production use with significant funds.**

[![Swift 6.1](https://img.shields.io/badge/Swift-6.1-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%20%7C%20macOS%20%7C%20tvOS%20%7C%20watchOS%20%7C%20visionOS%20%7C%20Linux-blue.svg)](https://swift.org)
[![Swift Package Manager](https://img.shields.io/badge/Swift%20Package%20Manager-compatible-brightgreen.svg)](https://github.com/apple/swift-package-manager)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A platform-agnostic Swift package implementing the Cashu ecash protocol. CoreCashu
provides a type-safe API for integrating Cashu wallet functionality into your
applications on any Swift-supported platform.

## Current Status

The single source of truth for per-NUT status is [`Docs/NUT_STATUS.md`](Docs/NUT_STATUS.md).
For a list of breaking changes see [`CHANGELOG.md`](CHANGELOG.md) and
[`Docs/migration_guide.md`](Docs/migration_guide.md).

| Area | Status |
|------|--------|
| Wire-protocol correctness (NUT-00, 02, 03, 04, 05, 11, 12, 13, 14, 18, 19, 24) | ✅ Spec vectors pass where they exist |
| High-level wallet API (mint, melt, swap, send, receive, P2PK, HTLC, restore) | ✅ Public surface, capability-gated |
| Cross-platform (Linux + Apple) | ✅ CryptoKit removed; URLSession HTTP, injectable WebSockets |
| Strict concurrency (`-strict-concurrency=complete` in debug + release) | ✅ Swift 6 language mode |
| Test suite | ✅ 1047 Swift Testing tests pass against in-process MockMint |
| `@_exported` dependency leaks | ✅ Removed (Phase 7.1) — consumers must `import P256K` etc. explicitly |
| Capability gating at the public API | ✅ `requireCapability(_:operation:)` + per-operation gates |
| NUT-21 (Clear auth / JWT) | 🔧 Signature verification is a stub — capability flag must stay off |
| NUT-22 (Blind auth / BAT) | 🔧 Endpoint and header shape don't match spec — capability flag must stay off |
| External security audit | ⏳ Pending |

### What's not yet supported

- **NUT-15 (Multi-path payments)** — type definitions only; no end-to-end routing.
- **NUT-17 (WebSocket subscriptions)** — `RobustWebSocketClient` exists but lacks a deterministic reconnect-and-resume integration test against the MockMint (HTTP-only).
- **NUT-21 / NUT-22** — see above; do not advertise to mints that require them.
- **NUT-23 (multi-sig + keyset delegation)** — types only.
- **NUT-25 / 26 / 27 / 28 / 29** — not implemented locally; per-NUT decisions deferred until v1 use cases appear.

## Features

- ✅ **Protocol-correct NUTs**: see [`Docs/NUT_STATUS.md`](Docs/NUT_STATUS.md) for the per-NUT matrix
- ✅ **Thread-Safe**: Swift actor model throughout; `Sendable`-audited types
- ✅ **Type-Safe**: Strict concurrency enforced in debug and release
- ✅ **Cross-platform**: Apple + Linux with no CryptoKit dependency
- ✅ **Deterministic Secrets**: BIP39/BIP32 (PBKDF2-HMAC-SHA-512, 2048 iterations)
- ✅ **Multiple Token Formats**: V3 JSON and V4 CBOR
- ✅ **Advanced Spending Conditions**: P2PK (NUT-11) and HTLC (NUT-14) end-to-end
- ✅ **Capability-gated**: optional NUTs throw `CashuError.unsupportedOperation` when the connected mint doesn't advertise support

## Installation

### Swift Package Manager

Add CoreCashu to your project using Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/SparrowTek/CoreCashu", from: "0.1.0")
]
```

Or add it through Xcode:
1. File → Add Package Dependencies
2. Enter: `https://github.com/SparrowTek/CoreCashu`
3. Choose your version requirements

## Quick Start

```swift
import CoreCashu

// Create wallet configuration (throws if mint URL is malformed)
let config = try WalletConfiguration(
    mintURL: "https://testnut.cashu.space",
    unit: "sat"
)

// Option 1: Create a wallet with default implementations (in-memory storage)
let wallet = await CashuWallet(configuration: config)

// Option 2: Create a wallet with custom implementations for your platform
let secureStore = MyPlatformSecureStore() // Implement SecureStore protocol
let logger = MyPlatformLogger()           // Implement LoggerProtocol
let customWallet = await CashuWallet(
    configuration: config,
    secureStore: secureStore,
    logger: logger
)

// Initialize the wallet
try await wallet.initialize()

// Check balance
let balance = try await wallet.balance
print("Current balance: \(balance) sats")

// Mint tokens using a Lightning invoice (BOLT11)
let mintResult = try await wallet.mint(
    amount: 1000,
    paymentRequest: "lnbc...",
    method: "bolt11"
)
// New proofs are available in mintResult.newProofs

// Send tokens
let token = try await wallet.send(amount: 500, memo: "Payment for coffee")

// Receive tokens
let receivedProofs = try await wallet.receive(token: token)

// Melt tokens via Lightning (pay a BOLT11 invoice)
let meltResult = try await wallet.melt(
    paymentRequest: "lnbc5u1p3...",
    method: "bolt11"
)
```

### Metrics and Logging

- The logger supports categories and levels with sensitive-field redaction by default.
- Metrics are optional via `MetricsSink`. For development:

```swift
logger.setMetricsSink(ConsoleMetricsSink())
logger.metricIncrement("CoreCashu.example.counter", by: 1, tags: ["env": "dev"]) // optional manual metric
```

Production apps should provide a custom sink that forwards to your telemetry (e.g., StatsD, OpenTelemetry).

## Platform Abstraction

CoreCashu is designed to be platform-agnostic. It provides protocols that can be implemented for any platform:

### Protocol Abstractions

```swift
// Secure storage protocol for sensitive data
public protocol SecureStore: Sendable {
    func saveMnemonic(_ mnemonic: String) async throws
    func loadMnemonic() async throws -> String?
    func saveSeed(_ seed: Data) async throws
    func loadSeed() async throws -> Data?
    func saveAccessToken(_ token: String, for clientId: String) async throws
    func loadAccessToken(for clientId: String) async throws -> String?
    func deleteAll() async throws
}

// Logging protocol for debugging and monitoring
public protocol LoggerProtocol: Sendable {
    func debug(_ message: String, file: String, function: String, line: Int)
    func info(_ message: String, file: String, function: String, line: Int)
    func warning(_ message: String, file: String, function: String, line: Int)
    func error(_ message: String, file: String, function: String, line: Int)
}

// WebSocket protocol for real-time communication
public protocol WebSocketClientProtocol: Sendable {
    var isConnected: Bool { get async }
    func connect(to url: URL) async throws
    func send(text: String) async throws
    func send(data: Data) async throws
    func receive() async throws -> WebSocketMessage
    func ping() async throws
    func close(code: WebSocketCloseCode, reason: Data?) async throws
    func disconnect() async
}
```

### Platform-Specific Implementations

For Apple platforms, CoreCashu defaults to:
- `KeychainSecureStore` for `SecureStore` (provided by CoreCashu under `#if canImport(Security)`)
- `OSLogger` for `LoggerProtocol` (provided by CoreCashu under `#if canImport(os)`)
- `URLSession` for HTTP via `URLSession.shared`
- WebSockets: inject `WebSocketClientProtocol`. CashuKit provides an Apple `URLSessionWebSocketTask`-based implementation.

For Linux, you must provide:
- `FileSecureStore(password:)` (or another `SecureStore`) — the no-password default is gone (Phase 3.5). PBKDF2-HMAC-SHA-256 derives the AES key from the password.
- `ConsoleLogger` (provided) or your own `LoggerProtocol`.
- `URLSession` for HTTP works via `FoundationNetworking`.
- WebSockets: inject your own `WebSocketClientProtocol` (e.g., `swift-nio`/`async-http-client`-backed) or accept `NoOpWebSocketClientProtocol`.

### Default Implementations

CoreCashu provides default implementations for development and testing:
- `InMemorySecureStore` - Non-persistent storage for testing
- `ConsoleLogger` - Simple console output logging
- `NoOpWebSocketClient` - No-operation WebSocket for offline testing

## Advanced Features

### Deterministic Secrets (NUT-13)

```swift
// Create wallet with mnemonic for backup/restore
let mnemonic = try CashuWallet.generateMnemonic()
let wallet = try await CashuWallet(
    configuration: config,
    mnemonic: mnemonic
)

// Restore wallet from mnemonic
let restoredWallet = try await CashuWallet(
    configuration: config,
    mnemonic: savedMnemonic
)
```

For deterministic test scenarios, prefer scoped RNG overrides:

```swift
let mnemonic = try SecureRandom.withGenerator({ count in
    Data(repeating: 0, count: count)
}) {
    try CashuWallet.generateMnemonic(strength: 128)
}
```

### Spending Conditions (NUT-10/11) and HTLC (NUT-14)

The wallet exposes high-level entry points for both:

```swift
// Lock funds to a recipient pubkey (NUT-11)
let token = try await wallet.sendLocked(amount: 100, to: recipientPubKey, memo: "for coffee")

// Recipient unlocks with their private key
let proofs = try await wallet.unlockP2PK(token: token, privateKey: recipientPrivKey)

// Hash time-locked contracts (NUT-14)
let htlc = try await wallet.createHTLC(amount: 100, locktime: Date().addingTimeInterval(3600))
let unlocked = try await wallet.redeemHTLC(token: htlc.token, preimage: htlc.preimage)
```

Both paths are gated behind their `MintFeatureCapability` (`.p2pk`, `.htlc`) — the
wallet throws `CashuError.unsupportedOperation` when the connected mint does not
advertise the capability in its `MintInfo`. See `Tests/CoreCashuTests/MockMintLockedSpendingTests.swift`
for end-to-end exercises.

### Token State Management (NUT-07)

```swift
// Check proof states
let batch = try await wallet.checkProofStates(myProofs)
for result in batch.results {
    print("Proof \(try result.proof.calculateY()): \(result.stateInfo.state)")
}

// Restore from seed (NUT-13)
let restoredBalance = try await wallet.restoreFromSeed(batchSize: 100) { progress in
    // handle progress updates
}
```

## Security

CoreCashu has completed comprehensive security hardening in preparation for external audit. See the full documentation in the `Docs/` directory.

### Security & Status Documentation
- **[NUT Status Matrix](Docs/NUT_STATUS.md)**: Per-NUT implementation, vector-test, and capability-flag status. Authoritative source for "what's supported." Tracks upstream `cashubtc/nuts`.
- **[Threat Model](Docs/threat_model.md)**: STRIDE analysis, trust boundaries, asset classification
- **[Security Assumptions](Docs/security_assumptions.md)**: Platform trust, cryptographic assumptions
- **[Audit Scope](Docs/audit_scope.md)**: Security-critical code paths for review
- **[Static Analysis Report](Docs/static_analysis_report.md)**: Code quality findings

### Implemented Security Features
- **Cryptographic Security**: All operations use `SecureRandom` (platform CSPRNG), constant-time comparisons via `SecureMemory`, memory zeroization for sensitive data
- **Secure Storage**: `KeychainSecureStore` (Apple) with biometric protection, `FileSecureStore` (Linux) with AES-GCM encryption, master-key rotation
- **Network Resilience**: Rate limiting (token bucket algorithm), circuit breakers (closed/open/half-open states), automatic retry with exponential backoff
- **Concurrency Safety**: Actor-based isolation, `Sendable`-audited types, no data races
- **Input Validation**: BIP39 mnemonic validation, proof validation, comprehensive error handling

### Audit Status
CoreCashu is **preparing for external security audit**. As of Phase 7 of `/opus47.md`:
- 1047 Swift Testing tests pass against an in-process `MockMint` (no live mint required for CI)
- BIP32/BIP39 implementation verified against official NUT-13 test vectors
- BDHKE, NUT-11 P2PK, and NUT-12 DLEQ all verify spec vectors end-to-end
- Force unwraps, force casts, `try!`, and stray `print()` removed from production code
- Strict concurrency enforced in **both** debug and release (Swift 6 language mode)
- `@_exported` dependency leaks removed; public API surface narrowed
- `MintFeatureCapabilities` is now wired as a runtime contract — optional NUTs throw `CashuError.unsupportedOperation` when the connected mint doesn't advertise them
- NUT-21 (Clear auth / JWT) and NUT-22 (Blind auth / BAT) are explicitly **not yet correct on the wire**; their capability flags must stay off

**Production use with significant funds should await completion of external audit.**

For the full per-phase work log see [`/opus47.md`](../opus47.md).

## Platform Support

CoreCashu is intentionally platform-agnostic. The full target matrix is:

### Apple Platforms (verified)
- iOS 17.0+
- macOS 15.0+
- tvOS 17.0+
- watchOS 10.0+
- visionOS 1.0+ / macCatalyst 17.0+

### Linux
- Linux is a first-class target for CoreCashu. As of Phase 3 of `opus47.md`, all `CryptoKit` usage has been replaced by the cross-platform `Hash` module (CryptoSwift-backed). Apple-only frameworks (`Security`, `os.log`, `CryptoKit`) are guarded with `#if canImport(...)`; the code paths that depend on them no-op or are absent on Linux.
- **HTTP** uses `URLSession` (available on Linux through `FoundationNetworking`) — no extra dependency needed for the request/response path. Bring your own `HTTPClientProtocol` if you want a different transport.
- **WebSocket subscriptions (NUT-17)** are an opt-in feature. CoreCashu defines `WebSocketClientProtocol` and ships `NoOpWebSocketClientProtocol` as a default. On Apple, CashuKit provides a `URLSessionWebSocketTask`-based implementation. On Linux, inject your own implementation (e.g., wrapping `swift-nio` / `async-http-client`). The internal `NUT17WebSocketClient` type uses `URLSessionWebSocketTask` directly and is best-tested on Apple.
- **Secure storage** on non-Apple platforms requires a password (or other key-protection mechanism). `FileSecureStore(password:)` derives the AES key via PBKDF2-HMAC-SHA-256. The previous no-password default has been removed (Phase 3.5) — see [`Docs/security_assumptions.md`](Docs/security_assumptions.md). On non-Apple platforms `CashuWallet`'s default `secureStore` is `nil`; consumers must inject one explicitly.

### Windows
- Untested. Should work in principle once the Linux work is verified in CI, since the same constraints apply (no Apple frameworks).

## Dependencies

- [swift-secp256k1](https://github.com/21-DOT-DEV/swift-secp256k1) - Elliptic curve cryptography
- [BigInt](https://github.com/attaswift/BigInt) - Large number arithmetic
- [CryptoSwift](https://github.com/krzyzanowskim/CryptoSwift) - Cryptographic functions
- [SwiftCBOR](https://github.com/valpackett/SwiftCBOR) - CBOR encoding/decoding

Note: CoreCashu includes a built-in BIP39 implementation for cross-platform mnemonic generation and wallet recovery.

## Testing

Run tests using Swift Package Manager:

```bash
swift test
```

Or in Xcode:
- ⌘+U to run all tests

## Contributing

We welcome contributions! However, please note that this library is not yet production ready. Areas that need work:

1. Security hardening and audit
2. Complete test coverage
3. Performance optimization
4. Documentation improvements
5. Missing NUT implementations

Please open an issue to discuss major changes before submitting a PR.

## License

CoreCashu is released under the MIT License. See [LICENSE](LICENSE) for details.

## Acknowledgments

- [Cashu Protocol](https://docs.cashu.space) - The underlying ecash protocol
- [cashubtc/nuts](https://github.com/cashubtc/nuts) - Protocol specifications

---

**Status**: Beta - Security audit preparation complete. External audit pending before production use with significant funds.
