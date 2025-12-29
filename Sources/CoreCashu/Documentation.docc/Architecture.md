# Architecture Overview

Learn about CoreCashu's architecture and how to integrate it into your applications.

## Overview

CoreCashu is designed as a platform-agnostic implementation of the Cashu ecash protocol. It provides the core protocol logic while allowing platform-specific implementations for storage, networking, and security.

### Architectural Layers

```
┌─────────────────────────────────────────┐
│           Your Application              │
├─────────────────────────────────────────┤
│              CashuWallet                │  ← Main entry point
│          (Actor - Thread-safe)          │
├─────────────────────────────────────────┤
│           Protocol Services             │
│  NUT-00 through NUT-22 implementations  │
├─────────────────────────────────────────┤
│         Platform Abstractions           │
│  SecureStore, Logger, WebSocket, etc.   │
├─────────────────────────────────────────┤
│        Cryptographic Primitives         │
│   BDHKE, BIP39, BIP32, secp256k1       │
└─────────────────────────────────────────┘
```

## Core Components

### CashuWallet

The ``CashuWallet`` actor is the main entry point for all wallet operations. It coordinates between:

- **Proof Management**: Storing and selecting proofs for operations
- **Mint Communication**: Handling all protocol interactions
- **State Management**: Tracking wallet state and balances

```swift
let wallet = await CashuWallet(configuration: config)
try await wallet.initialize()
```

### Protocol Implementations (NUTs)

Each NUT (Notation, Usage, Terminology) specification is implemented as a separate module:

| Module | Description |
|--------|-------------|
| NUT-00 | Cryptographic primitives and token formats |
| NUT-01 | Mint public key exchange |
| NUT-02 | Keysets and keyset IDs |
| NUT-03 | Token swapping |
| NUT-04 | Minting tokens |
| NUT-05 | Melting tokens |
| NUT-06 | Mint information |
| NUT-07 | Token state checking |
| NUT-09 | Wallet restoration |
| NUT-10 | Spending conditions |
| NUT-11 | Pay-to-Public-Key (P2PK) |
| NUT-12 | DLEQ proofs |
| NUT-13 | Deterministic secrets |
| NUT-14 | HTLCs |

### Platform Abstractions

CoreCashu defines protocols for platform-specific functionality:

#### SecureStore

```swift
public protocol SecureStore: Sendable {
    func saveMnemonic(_ mnemonic: String) async throws
    func loadMnemonic() async throws -> String?
    func saveSeed(_ seed: Data) async throws
    func loadSeed() async throws -> Data?
}
```

Implementations:
- ``InMemorySecureStore`` - Testing only
- ``FileSecureStore`` - Linux/server with AES-GCM encryption
- `KeychainSecureStore` (CashuKit) - Apple platforms

#### ProofStorage

```swift
public protocol ProofStorage: Sendable {
    func storeProofs(_ proofs: [Proof]) async throws
    func retrieveProofs(forKeysetId: String?) async throws -> [Proof]
    func removeProofs(_ proofs: [Proof]) async throws
}
```

### Security Components

#### SecureRandom

All cryptographic randomness uses platform-specific CSPRNGs:

```swift
let randomBytes = try SecureRandom.generateBytes(count: 32)
```

#### SecureMemory

Provides secure memory handling:

```swift
// Constant-time comparison
let equal = SecureMemory.constantTimeCompare(a, b)

// Secure data wrapper with automatic zeroization
let sensitive = SensitiveData(data)
defer { sensitive.wipe() }
```

### Network Resilience

#### Rate Limiter

Token bucket algorithm prevents overwhelming mints:

```swift
let rateLimiter = RateLimiter(config: .default)
if await rateLimiter.shouldAllowRequest() {
    // Make request
}
```

#### Circuit Breaker

Prevents cascading failures:

```swift
let breaker = CircuitBreaker(config: .default)
try await breaker.execute {
    // Network operation
}
```

## Threading Model

CoreCashu uses Swift's structured concurrency:

1. **CashuWallet** is an actor - all state access is serialized
2. **Services** are Sendable - safe to pass between isolation domains
3. **Data types** are Sendable - can be shared across threads

```swift
// Safe concurrent access
async let balance = wallet.balance
async let proofs = wallet.getAvailableProofs()
```

## Error Handling

Errors are categorized for appropriate handling:

```swift
enum CashuError {
    // Network errors - may be retryable
    case networkError(underlying: Error)
    
    // Validation errors - not retryable
    case invalidToken(reason: String)
    
    // Cryptographic errors - not retryable
    case cryptographicError(operation: String)
}
```

Use ``CashuError/isRetryable`` to determine retry strategy.

## Integration Patterns

### Apple Platforms (via CashuKit)

```swift
import CashuKit

let wallet = await AppleCashuWallet()
try await wallet.connect(to: mintURL)
```

### Linux/Server

```swift
import CoreCashu

let secureStore = FileSecureStore(directory: dataDir)
let wallet = await CashuWallet(
    configuration: config,
    secureStore: secureStore
)
```

### Custom Implementations

Implement the required protocols for your platform:

```swift
final class MySecureStore: SecureStore {
    func saveMnemonic(_ mnemonic: String) async throws {
        // Your implementation
    }
    // ... other methods
}
```

## See Also

- ``CashuWallet``
- ``SecureStore``
- ``ProofStorage``
- <doc:Security>
