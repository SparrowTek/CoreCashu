# CoreCashu

> **BETA STATUS** - Security Audit Preparation Complete
> 
> CoreCashu has completed comprehensive security hardening and audit preparation:
> - 660+ tests passing with ~75% code coverage
> - Full threat model and security assumptions documented
> - Rate limiting, circuit breakers, and secure storage implemented
> - BIP39/BIP32 implementation verified against NUT-13 test vectors
> - Constant-time operations and memory zeroization in place
> 
> **Pending external security audit before production use with significant funds.**
> See [Security Documentation](Docs/threat_model.md) for details.

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
- **External Security Audit**: Ready for third-party review
- **Additional NUTs**: DLCs (NUT-XX), subscription model improvements

### ❌ Not Yet Implemented
- **Advanced Features**: DLCs, some subscription model features
- **Certificate Pinning**: TLS certificate pinning for enhanced security

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

## Security

CoreCashu has completed comprehensive security hardening in preparation for external audit. See the full documentation in the `Docs/` directory.

### Security Documentation
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
CoreCashu is **ready for external security audit**. The following have been completed:
- 660+ tests passing with ~75% code coverage
- BIP32/BIP39 implementation verified against official NUT-13 test vectors
- No force unwraps, force casts, or force try in production code
- All `@unchecked Sendable` usages documented and audited
- Zero compiler warnings

**Production use with significant funds should await completion of external audit.**

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

**Status**: Beta - Security audit preparation complete. External audit pending before production use with significant funds.
