# CoreCashu

> ⚠️ **WARNING: NOT PRODUCTION READY** ⚠️
> 
> This library is under active development and is NOT yet suitable for production use.
> - Security features are still being implemented
> - API may change significantly
> - Some critical features are incomplete
> - Not audited for security vulnerabilities
> 
> **DO NOT USE WITH REAL FUNDS**

[![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%20%7C%20macOS%20%7C%20tvOS%20%7C%20watchOS%20%7C%20visionOS%20%7C%20Linux-blue.svg)](https://swift.org)
[![Swift Package Manager](https://img.shields.io/badge/Swift%20Package%20Manager-compatible-brightgreen.svg)](https://github.com/apple/swift-package-manager)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A platform-agnostic Swift package implementing the Cashu ecash protocol. CoreCashu provides a type-safe API for integrating Cashu wallet functionality into your applications on any Swift-supported platform.

## Current Status

### ✅ Implemented
- **Core Protocol**: NUT-00 through NUT-06, NUT-07, NUT-08, NUT-09, NUT-10, NUT-11, NUT-12, NUT-13, NUT-14, NUT-15, NUT-16, NUT-17, NUT-19, NUT-20, NUT-22
- **Wallet Operations**: Mint, melt, swap, send, receive
- **Token Management**: V3/V4 token serialization, CBOR support
- **Cryptography**: BDHKE, deterministic secrets, P2PK, HTLCs, BIP39 mnemonic generation
- **State Management**: Actor-based concurrency, thread safety
- **Error Handling**: Comprehensive error types and recovery
- **Platform Abstraction**: Protocol-based design for cross-platform support
- **Authentication**: NUT-22 access token support
- **Restoration**: Wallet restoration from mnemonic (NUT-13)

### 🚧 In Progress
- **Platform Integrations**: Native implementations for Keychain (Apple), file storage (Linux), etc.

### ❌ Not Implemented
- **Advanced Features**: DLCs, subscription model
- **Production Hardening**: Rate limiting, circuit breakers
- **Testing**: Full test coverage, integration tests

## Features

- ✅ **NUT Implementation**: Supports NUT-00 through NUT-22 (with some gaps)
- ✅ **Thread-Safe**: Built with Swift's actor model for concurrent operations
- ✅ **Type-Safe**: Leverages Swift's type system for compile-time safety
- ✅ **SwiftUI Ready**: Designed for easy integration with SwiftUI applications
- ✅ **Deterministic Secrets**: BIP39/BIP32 support for wallet recovery
- ✅ **Multiple Token Formats**: V3 JSON and V4 CBOR token formats
- ✅ **Advanced Spending Conditions**: P2PK and HTLC support

## Supported Cashu NIPs (NUTs)

### Core Protocol
- **NUT-00**: Notation, Terminology and Types
- **NUT-01**: Mint public key exchange
- **NUT-02**: Keysets and keyset IDs
- **NUT-03**: Swap tokens (exchange proofs)
- **NUT-04**: Mint tokens
- **NUT-05**: Melting tokens
- **NUT-06**: Mint information

### Token Formats
- **NUT-00**: V3 Token Format (JSON-based)
- **NUT-00**: V4 Token Format (CBOR-based)

### Advanced Features
- **NUT-07**: Token state check
- **NUT-08**: Lightning fee return
- **NUT-09**: Wallet restore from seed
- **NUT-10**: Spending conditions (P2PK)
- **NUT-11**: Pay-to-Public-Key (P2PK)
- **NUT-12**: Offline ecash signature validation (DLEQ)
- **NUT-13**: Deterministic secrets (BIP39/BIP32)
- **NUT-14**: Hash Time Locked Contracts (HTLCs)
- **NUT-15**: Multi-path payments (MPP)
- **NUT-16**: Animated QR codes
- **NUT-17**: WebSocket subscriptions
- **NUT-19**: Mint Management
- **NUT-20**: Bitcoin On-Chain Support
- **NUT-22**: Non-custodial wallet authentication

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

// Create wallet configuration
let config = WalletConfiguration(
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
    func connect() async throws
    func disconnect() async
    func send(_ message: String) async throws
    func receive() async throws -> String
}
```

### Platform-Specific Implementations

For Apple platforms, you might use:
- Keychain for `SecureStore`
- os.log for `LoggerProtocol`
- URLSession for `WebSocketClientProtocol`

For Linux, you might use:
- File system with encryption for `SecureStore`
- Custom file logging for `LoggerProtocol`
- SwiftNIO for `WebSocketClientProtocol`

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

### Spending Conditions (NUT-10/11)

Support exists in lower-level services and models; high-level wallet helpers are under development. Refer to NUT-10/11 modules and tests for current usage patterns.

### HTLC Support (NUT-14)

HTLC primitives are implemented in the model layer. High-level wallet flows are planned; see NUT-14 tests for examples.

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

## Security Considerations

⚠️ **CoreCashu remains unaudited and must not be connected to real funds.** The points below track our active security posture and the gates that must close before we relax the production warning.

### Implemented safeguards
- All production call sites now route through `SecureRandom.generateBytes`, with failure paths surfaced via `SecureRandomError` and deterministic overrides available for tests (see `Docs/security_audit.md`).
- Cryptographic primitives lean on `swift-secp256k1`, CryptoKit, and CryptoSwift with constant-time operations where available; BDHKE, P2PK, and HTLC flows are regression-tested under `Tests/CoreCashuTests/CryptographicTests.swift`.
- Wallet state is isolated behind actors and `Sendable`-audited types to prevent concurrency data races.
- The file-backed secure store encrypts at rest using AES.GCM, enforces `0o600` permissions, zeroizes files best-effort on deletion, and rejects malformed ciphertext.

### Secure storage status
- `KeychainSecureStore` now backs Apple platforms by default, keeping mnemonics and tokens inside the system Keychain. Manual validation and entitlement requirements are tracked in `Docs/keychain_secure_store_plan.md`. When building on Apple platforms you can require user presence, biometrics, or passcode enforcement via the wallet configuration's Keychain access-control settings (see ``WalletConfiguration``), e.g. `WalletConfiguration(mintURL: "…", keychainAccessControl: .userPresence)`.
- `FileSecureStore` now ships with envelope-based AES-GCM encryption, master-key rotation, and optional password-derived keys for Linux/server environments. Pair it with host hardening, filesystem permissions, and encrypted backups for defense in depth.
- `InMemorySecureStore` stays available for tests and ephemeral demos but is now deprecated; production apps must depend on the platform stores above.

### Threat model snapshot
- **Local compromise:** Key material is Keychain-backed on Apple and AES.GCM-encrypted on Linux today, but biometric-gated usage still depends on host entitlements and validation on real devices. See `Docs/threat_model.md` for mitigation tables and residual risks.
- **Network/mint surface:** HTTPS/TLS pinning, retry limits, and mint DOS protections are not yet implemented. Clients must assume the mint can observe request metadata until rate limiting and circuit breakers ship (see `Docs/production_gaps.md`).
- **Implementation defects:** BIP39/BIP32 derivation is covered by deterministic tests, but additional BIP32 compliance vectors are still TODO in `Tests/CoreCashuTests/NUT13Tests.swift`. Serialization fuzzing and adversarial input suites are scheduled for Phase 6.

### Audit expectations
- Third-party cryptography and security review is a release blocker. The draft threat model (`Docs/threat_model.md`) and keychain rollout plan (`Docs/keychain_secure_store_plan.md`) must be completed and reviewed before hand-off.
- Before commissioning the audit, finish the secure storage program (Keychain hardened with AccessControl, Linux parity), add networking rate limiting/circuit breakers, and land telemetry hooks to monitor key flows.
- Until those gates close, keep CoreCashu deployments limited to mocks, tests, or controlled demonstrations.

## Platform Support

### Apple Platforms
- iOS 17.0+
- macOS 15.0+
- tvOS 17.0+
- watchOS 10.0+
- visionOS 1.0+

### Other Platforms
- Linux (Ubuntu 20.04+, other distributions with Swift 6.0 support)
- Windows (experimental, with Swift 6.0 toolchain)

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

**Remember**: This is experimental software. Use at your own risk and only with testnet funds.
