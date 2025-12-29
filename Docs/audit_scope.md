# CoreCashu Security Audit Scope Document

> **Version:** 1.0
> **Date:** December 29, 2025
> **Package Version:** Pre-release (development)

## 1. Executive Summary

CoreCashu is a Swift implementation of the Cashu ecash protocol designed for cross-platform use. This document defines the scope for security audit, including code boundaries, dependencies, security-sensitive paths, and known limitations.

**Audit Type Recommended:** Full security audit with focus on:
- Cryptographic implementation correctness
- State machine integrity (proof lifecycle)
- Input validation completeness
- Secret handling and storage security

---

## 2. Codebase Overview

### 2.1 Repository Structure

```
CoreCashu/
├── Sources/CoreCashu/           # Main library source (106 files, ~28,000 LOC)
│   ├── Core/                    # Core types, networking, validation
│   ├── DefaultImplementations/  # Default protocol implementations
│   ├── Errors/                  # Error types and handling
│   ├── HighLevelAPI/            # Simplified wallet operations
│   ├── Models/                  # Data models (Proof, Token, etc.)
│   ├── Networking/              # HTTP client abstractions
│   ├── NUTs/                    # Protocol implementations (NUT-00 to NUT-22)
│   ├── Observability/           # Logging, metrics, telemetry
│   ├── Protocols/               # Protocol definitions
│   ├── Resources/               # BIP39 wordlist
│   ├── SecureStorage/           # Keychain, FileSecureStore
│   ├── Security/                # SecureMemory, secret handling
│   ├── Services/                # Business logic services
│   ├── Storage/                 # Proof storage, counters
│   ├── Utils/                   # Utilities (BIP39, validation, etc.)
│   └── WebSockets/              # WebSocket client (NUT-17)
│
├── Tests/CoreCashuTests/        # Test suite (650+ tests)
└── Docs/                        # Security documentation
```

### 2.2 Language & Build

| Attribute | Value |
|-----------|-------|
| Language | Swift 6.0 |
| Build System | Swift Package Manager |
| Minimum Platforms | iOS 15, macOS 12, visionOS 1, watchOS 8, tvOS 15 |
| Linux Support | Yes (SPM) |
| Concurrency Model | Swift structured concurrency (actors, async/await) |

---

## 3. In-Scope Code

### 3.1 Security-Critical Components (Priority 1)

| Component | Location | Lines | Description |
|-----------|----------|-------|-------------|
| **NUT-00 BDHKE** | `NUTs/NUT00.swift` | ~500 | Blind Diffie-Hellman Key Exchange core |
| **BIP39** | `Utils/BIP39.swift` | ~400 | Mnemonic generation/validation |
| **SecureRandom** | `Utils/SecureRandom.swift` | ~100 | CSPRNG wrapper |
| **SecureMemory** | `Security/SecureMemory.swift` | ~200 | Memory wiping, constant-time ops |
| **FileSecureStore** | `SecureStorage/FileSecureStore.swift` | ~400 | Encrypted file storage |
| **KeychainSecureStore** | `SecureStorage/KeychainSecureStore.swift` | ~300 | Apple Keychain wrapper |
| **NUT-11 P2PK** | `NUTs/NUT11.swift` | ~600 | Pay-to-Public-Key signatures |
| **NUT-12 DLEQ** | `NUTs/NUT12.swift` | ~300 | Discrete Log Equality proofs |
| **NUT-13 Derivation** | `NUTs/NUT13.swift` | ~400 | Deterministic secret derivation |
| **NUT-14 HTLC** | `NUTs/NUT14.swift` | ~500 | Hash Time-Locked Contracts |

### 3.2 State Management Components (Priority 2)

| Component | Location | Lines | Description |
|-----------|----------|-------|-------------|
| **CashuWallet** | `CashuWallet.swift` | ~2000 | Main wallet actor |
| **ProofManager** | `Storage/ProofStorage.swift` | ~400 | Proof lifecycle management |
| **ProofStateManager** | `Storage/ProofStateManager.swift` | ~200 | State transitions |
| **KeysetCounterManager** | `Storage/KeysetCounterStorage.swift` | ~200 | NUT-13 counter management |

### 3.3 Network & Validation Components (Priority 3)

| Component | Location | Lines | Description |
|-----------|----------|-------|-------------|
| **NUTValidation** | `Core/NUTValidation.swift` | ~600 | Input validation |
| **ValidationUtils** | `Utils/ValidationUtils.swift` | ~300 | URL, hex, format validation |
| **TokenUtils** | `Utils/TokenUtils.swift` | ~600 | Token serialization |
| **NetworkRouter** | `Networking/Service/NetworkRouter.swift` | ~200 | HTTP client |
| **RateLimiter** | `Utils/RateLimiter.swift` | ~200 | Request throttling |
| **CircuitBreaker** | `Utils/CircuitBreaker.swift` | ~200 | Failure isolation |

### 3.4 Additional NUT Implementations (Priority 3)

| NUT | Location | Description |
|-----|----------|-------------|
| NUT-01 | `NUTs/NUT01.swift` | Mint keys |
| NUT-02 | `NUTs/NUT02.swift` | Keysets |
| NUT-03 | `NUTs/NUT03.swift` | Swap |
| NUT-04 | `NUTs/NUT04.swift` | Minting |
| NUT-05 | `NUTs/NUT05.swift` | Melting |
| NUT-06 | `NUTs/NUT06.swift` | Mint info |
| NUT-07 | `NUTs/NUT07.swift` | Token state check |
| NUT-08 | `NUTs/NUT08.swift` | Fee return |
| NUT-09 | `NUTs/NUT09.swift` | Restore |
| NUT-10 | `NUTs/NUT10.swift` | Spending conditions |
| NUT-17 | `NUTs/NUT17.swift` | WebSocket subscriptions |
| NUT-20 | `NUTs/NUT20.swift` | Mint quotes |
| NUT-21 | `NUTs/NUT21.swift` | OAuth/OIDC |
| NUT-22 | `NUTs/NUT22.swift` | Access tokens |

---

## 4. Out of Scope

### 4.1 Excluded from This Audit

| Component | Reason |
|-----------|--------|
| `CashuKit/` package | Apple-specific integrations; separate audit scope |
| `swift-cashu-mint/` | Mint implementation; separate project |
| Test files | Not production code |
| Documentation | Non-executable |

### 4.2 Third-Party Dependencies

Dependencies should be audited separately or assumed trusted:

| Dependency | Version | Purpose | Trust Level |
|------------|---------|---------|-------------|
| swift-secp256k1 | 0.21.1+ | Elliptic curve ops | High (audited upstream) |
| CryptoSwift | 1.9.0+ | Symmetric crypto, hashing | Medium (widely used) |
| BigInt | 5.6.0+ | Large number arithmetic | Medium (mature) |
| SwiftCBOR | 0.5.0+ | CBOR encoding | Medium |

---

## 5. Security-Sensitive Code Paths

### 5.1 Secret Generation Flow

```
User Action: Create new wallet
    ↓
BIP39.generateMnemonic(strength:)
    ↓
SecureRandom.generateBytes(count:)  ← CRITICAL: RNG source
    ↓
Entropy → Mnemonic → Seed
    ↓
SecureStore.saveMnemonic()  ← CRITICAL: Storage security
```

**Audit Focus:**
- Verify `SecureRandom` uses platform CSPRNG correctly
- Verify entropy is sufficient (128-256 bits)
- Verify mnemonic is stored encrypted

### 5.2 Token Creation Flow (BDHKE)

```
Mint Request:
    ↓
SecureRandom.generateBytes() → secret  ← CRITICAL: Secret randomness
    ↓
NUT00.hashToCurve(secret) → Y
    ↓
SecureRandom.generateBytes() → blindingFactor (r)
    ↓
Y + r*G → B_ (blinded message)  ← CRITICAL: Blinding correctness
    ↓
Network: POST /v1/mint → C_ (blind signature)
    ↓
C_ - r*K → C (unblind)  ← CRITICAL: Unblinding correctness
    ↓
Store Proof(secret, C, keyset)
```

**Audit Focus:**
- Hash-to-curve implementation correctness
- Blinding factor generation and secrecy
- Unblinding operation correctness
- Signature verification before storage

### 5.3 Proof Spending Flow

```
Melt Request:
    ↓
ProofManager.selectProofs(amount)
    ↓
markAsPendingSpent(proofs)  ← CRITICAL: State transition
    ↓
Network: POST /v1/melt (proofs)
    ↓
Success? → finalizePendingSpent()  ← CRITICAL: Atomic commit
    ↓
Failure? → rollbackPendingSpent()  ← CRITICAL: Atomic rollback
```

**Audit Focus:**
- Proof selection doesn't allow double-selection
- Pending state prevents concurrent spend
- Rollback correctly restores state

### 5.4 Token Import Flow

```
User Input: Token string
    ↓
CashuTokenUtils.deserializeToken()  ← CRITICAL: Input parsing
    ↓
Validate structure (amounts, keyset, mint)
    ↓
Check for duplicates against storage
    ↓
(Optional) Verify with mint via /v1/checkstate
    ↓
Store proofs
```

**Audit Focus:**
- Parser doesn't crash on malformed input
- Duplicate detection is complete
- Amount overflow is prevented

### 5.5 Secure Storage Flow

```
Save Secret:
    ↓
[Apple] Keychain.add(secret, accessControl)
    ↓
[Linux] AES-GCM.encrypt(secret, key) → ciphertext
    ↓
        Write file with 0o600 permissions

Load Secret:
    ↓
[Apple] Keychain.load(service, accessControl)
    ↓
[Linux] Read file → AES-GCM.decrypt(ciphertext, key)
    ↓
Return SensitiveData wrapper (auto-wipes on deinit)
```

**Audit Focus:**
- Keychain access controls are correctly set
- AES-GCM nonces are unique per encryption
- File permissions are enforced
- Memory is wiped after use

---

## 6. Known Limitations & Risks

### 6.1 Acknowledged Limitations

| ID | Limitation | Impact | Mitigation |
|----|------------|--------|------------|
| L1 | Memory wiping is best-effort | Secrets may remain in memory | SensitiveData wrapper; documented limitation |
| L2 | No HSM/Secure Enclave integration | Keys in software memory | Future enhancement planned |
| L3 | JWT validation incomplete in NUT-21 | OAuth tokens may not be fully verified | Placeholder; needs implementation |
| L4 | Counter storage lacks integrity check | Counter manipulation possible | HMAC recommended |
| L5 | No proof freshness validation | Replay attacks possible | Timestamp verification recommended |

### 6.2 Known Gaps (To Be Fixed)

| ID | Issue | Location | Status |
|----|-------|----------|--------|
| G1 | BIP32 compliance tests incomplete | NUT13Tests.swift | Pending |
| G2 | Integration tests skipped | IntegrationTests.swift | Pending |
| G3 | Pending state has no timeout | ProofStateManager | Pending |

---

## 7. Test Coverage

### 7.1 Current State

| Metric | Value |
|--------|-------|
| Total Tests | 650+ |
| Test Files | 25+ |
| Coverage (estimated) | 75% |
| Coverage Target | 85% |

### 7.2 Security Test Categories

| Category | Tests | Status |
|----------|-------|--------|
| BDHKE Correctness | 20+ | Complete |
| BIP39 Generation | 42 | Complete |
| Proof Storage | 52 | Complete |
| Error Handling | 33 | Complete |
| Input Validation | 30+ | Complete |
| Concurrency | 10 | Complete |
| Cryptographic | 30+ | Complete |
| Rate Limiting | 20 | Complete |
| Circuit Breaker | 22 | Complete |

### 7.3 Missing Test Areas

- Fuzz testing for token deserialization
- Full mint/melt integration tests
- NUT-21 OAuth flow tests
- Cross-platform storage tests

---

## 8. Build & Verification

### 8.1 Build Commands

```bash
# Build library
cd CoreCashu
swift build

# Run tests
swift test

# Build for release
swift build -c release

# Generate coverage report
swift test --enable-code-coverage
```

### 8.2 Static Analysis

```bash
# SwiftLint (if configured)
swiftlint lint

# Build with all warnings as errors
swift build -Xswiftc -warnings-as-errors
```

---

## 9. Audit Deliverables Requested

### 9.1 Required Findings

| Category | Description |
|----------|-------------|
| Critical | Vulnerabilities allowing fund theft or key compromise |
| High | Vulnerabilities allowing significant security bypass |
| Medium | Issues that could lead to security degradation |
| Low | Minor issues or improvements |
| Informational | Observations and recommendations |

### 9.2 Specific Areas of Interest

1. **Cryptographic Correctness**
   - Is BDHKE implemented correctly per NUT-00 spec?
   - Are all signatures verified before acceptance?
   - Is hash-to-curve secure?

2. **State Machine Integrity**
   - Can proofs be double-spent via race conditions?
   - Are state transitions truly atomic?
   - Is rollback complete?

3. **Input Validation**
   - Are all external inputs validated?
   - Are there integer overflow risks?
   - Can malformed tokens cause crashes?

4. **Secret Handling**
   - Are secrets properly protected in memory?
   - Is storage encryption implemented correctly?
   - Are secrets redacted from logs?

5. **Concurrency Safety**
   - Are actors correctly isolating state?
   - Are there potential deadlocks?
   - Is async cancellation handled safely?

---

## 10. Contact & Coordination

### 10.1 Audit Coordination

- **Primary Contact:** [Project Maintainer]
- **Response Time:** 24-48 hours for clarifications
- **Secure Channel:** [To be established]

### 10.2 Disclosure Policy

- Vulnerabilities should be reported privately
- Coordinated disclosure after fix is available
- Credit will be given in security advisories

---

## Appendix A: File Listing (Security-Critical)

```
Sources/CoreCashu/
├── NUTs/
│   ├── NUT00.swift              # BDHKE implementation
│   ├── NUT11.swift              # P2PK signatures
│   ├── NUT12.swift              # DLEQ proofs
│   ├── NUT13.swift              # Deterministic derivation
│   └── NUT14.swift              # HTLC
├── SecureStorage/
│   ├── FileSecureStore.swift    # Encrypted file storage
│   └── KeychainSecureStore.swift # Apple Keychain
├── Security/
│   └── SecureMemory.swift       # Memory security
├── Utils/
│   ├── BIP39.swift              # Mnemonic handling
│   ├── SecureRandom.swift       # RNG wrapper
│   ├── TokenUtils.swift         # Token parsing
│   └── ValidationUtils.swift    # Input validation
└── Storage/
    └── ProofStorage.swift       # Proof lifecycle
```

## Appendix B: Dependency Versions

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1.git", from: "0.21.1"),
    .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", from: "1.9.0"),
    .package(url: "https://github.com/attaswift/BigInt.git", from: "5.6.0"),
    .package(url: "https://github.com/valpackett/SwiftCBOR.git", from: "0.5.0"),
]
```

---

*Document generated: December 29, 2025*
*For audit coordination, contact project maintainers.*
