# CoreCashu Threat Model

> **Status:** Complete - December 29, 2025
> **Version:** 2.0
> **Last Review:** December 29, 2025

## Executive Summary

This document provides a comprehensive threat model for CoreCashu, a Swift implementation of the Cashu protocol. CoreCashu handles cryptographic ecash tokens, making security paramount. This analysis follows the STRIDE methodology and identifies trust boundaries, assets, threats, and mitigations.

**Risk Summary:**
- **Critical Risks:** Mnemonic/seed exposure, cryptographic operation failures
- **High Risks:** Token theft, storage compromise, network MITM attacks
- **Medium Risks:** Double-spend attempts, proof replay, access token misuse
- **Low Risks:** DoS attacks (mitigated), timing side-channels

---

## 1. Scope

### 1.1 In-Scope Components
| Component | Description | Location |
|-----------|-------------|----------|
| CoreCashu Library | Cross-platform Cashu wallet implementation | `CoreCashu/Sources/CoreCashu/` |
| NUT Implementations | Protocol handlers (NUT-00 through NUT-22) | `CoreCashu/Sources/CoreCashu/NUTs/` |
| Secure Storage | Keychain, FileSecureStore, in-memory | `CoreCashu/Sources/CoreCashu/SecureStorage/` |
| Cryptographic Utils | BDHKE, BIP39, secure random | `CoreCashu/Sources/CoreCashu/Security/`, `Utils/` |
| Network Layer | HTTP client, WebSocket client | `CoreCashu/Sources/CoreCashu/Core/`, `WebSockets/` |
| Proof Management | Storage, selection, state tracking | `CoreCashu/Sources/CoreCashu/Storage/` |

### 1.2 Target Environments
- Apple platforms: iOS 15+, macOS 12+, visionOS 1+, watchOS 8+, tvOS 15+
- Linux server deployments (SPM)
- WASM (future consideration)

### 1.3 Out of Scope
- CashuKit Apple-specific integrations (documented separately)
- Mint-side implementation (`swift-cashu-mint`)
- Application-layer UI code
- Third-party dependencies (audited separately)

---

## 2. Trust Boundaries

### 2.1 Network ↔ Application Boundary

```
┌──────────────────────────────────────────────────────────────┐
│                     UNTRUSTED ZONE                           │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────┐    │
│  │  Internet   │     │    Mint     │     │  WebSocket  │    │
│  │   (TLS)     │     │   Server    │     │  Messages   │    │
│  └──────┬──────┘     └──────┬──────┘     └──────┬──────┘    │
└─────────┼───────────────────┼───────────────────┼────────────┘
          │                   │                   │
═════════════════════ TRUST BOUNDARY ════════════════════════════
          │                   │                   │
┌─────────▼───────────────────▼───────────────────▼────────────┐
│                      TRUSTED ZONE                            │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────┐    │
│  │ NetworkRouter│     │ NUT Handler │     │ WebSocket   │    │
│  │ + Validation │     │ + Decode    │     │ Client      │    │
│  └─────────────┘     └─────────────┘     └─────────────┘    │
└──────────────────────────────────────────────────────────────┘
```

**Crossing Points:**
| Endpoint | Method | NUT | Data Crossing |
|----------|--------|-----|---------------|
| `/v1/keys` | GET | NUT-01 | Mint public keys |
| `/v1/keysets` | GET | NUT-02 | Keyset metadata |
| `/v1/swap` | POST | NUT-03 | Proofs in, blind sigs out |
| `/v1/mint/quote/{method}` | POST | NUT-04 | Payment request |
| `/v1/mint/{method}` | POST | NUT-04 | Blinded messages → signatures |
| `/v1/melt/quote/{method}` | POST | NUT-05 | Invoice validation |
| `/v1/melt/{method}` | POST | NUT-05 | Proofs → payment |
| `/v1/info` | GET | NUT-06 | Mint capabilities |
| `/v1/checkstate` | POST | NUT-07 | Proof state queries |
| `/v1/restore` | POST | NUT-09 | Wallet restoration |
| WebSocket | WS | NUT-17 | Subscription events |

### 2.2 Storage ↔ Memory Boundary

```
┌──────────────────────────────────────────────────────────────┐
│                    PERSISTENT STORAGE                         │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────┐    │
│  │  Keychain   │     │ Encrypted   │     │   Counter   │    │
│  │  (Apple)    │     │ Files       │     │  Storage    │    │
│  └──────┬──────┘     └──────┬──────┘     └──────┬──────┘    │
└─────────┼───────────────────┼───────────────────┼────────────┘
          │                   │                   │
═════════════════════ TRUST BOUNDARY ════════════════════════════
          │                   │                   │
┌─────────▼───────────────────▼───────────────────▼────────────┐
│                      APPLICATION MEMORY                       │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────┐    │
│  │ SecureStore │     │  FileSecure │     │  Keyset     │    │
│  │ Protocol    │     │  Store      │     │  Counter    │    │
│  └─────────────┘     └─────────────┘     └─────────────┘    │
└──────────────────────────────────────────────────────────────┘
```

### 2.3 User Input ↔ Processing Boundary

```
┌──────────────────────────────────────────────────────────────┐
│                     USER INPUT (UNTRUSTED)                    │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────┐    │
│  │  Token      │     │  Mnemonic   │     │  Payment    │    │
│  │  Strings    │     │  Phrases    │     │  Requests   │    │
│  └──────┬──────┘     └──────┬──────┘     └──────┬──────┘    │
└─────────┼───────────────────┼───────────────────┼────────────┘
          │                   │                   │
═════════════════════ TRUST BOUNDARY ════════════════════════════
          │                   │                   │
┌─────────▼───────────────────▼───────────────────▼────────────┐
│                    INPUT VALIDATION LAYER                     │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────┐    │
│  │ TokenUtils  │     │ BIP39       │     │ NUT         │    │
│  │ deserialize │     │ validate    │     │ Validation  │    │
│  └─────────────┘     └─────────────┘     └─────────────┘    │
└──────────────────────────────────────────────────────────────┘
```

---

## 3. Assets & Sensitivity Classification

### 3.1 Critical Assets (Compromise = Total Loss)

| Asset | Location | Storage | Protection |
|-------|----------|---------|------------|
| **BIP39 Mnemonic** | `SecureStore.saveMnemonic()` | Keychain / Encrypted File | AES-GCM, access controls, memory wiping |
| **Seed Bytes** | `SecureStore.saveSeed()` | Keychain / Encrypted File | PBKDF2 derivation, never logged |
| **Blinding Factors** | `WalletBlindingData` | Ephemeral memory | Wiped after unblinding |
| **HTLC Preimages** | `NUT14` witness data | Proof storage | Time-locked, single use |

### 3.2 High-Sensitivity Assets (Compromise = Financial Loss)

| Asset | Location | Storage | Protection |
|-------|----------|---------|------------|
| **Proof.secret** | `Models/Proof.swift:13` | ProofStorage | Per-proof unique, BDHKE committed |
| **Proof.C** | `Models/Proof.swift:14` | ProofStorage | Unblinded signature, validates ownership |
| **Access Tokens** | NUT-21/22 handlers | SecureStore | Encrypted at rest, scoped |
| **Private Keys** | P2PK operations | Ephemeral | Never persisted, wiped after use |

### 3.3 Medium-Sensitivity Assets (Compromise = Privacy Loss)

| Asset | Location | Impact |
|-------|----------|--------|
| Mint URLs | WalletConfiguration | Fingerprinting, tracking |
| Transaction history | Proof storage timestamps | Spending pattern analysis |
| Keyset counters | KeysetCounterManager | Transaction count exposure |
| Invoice metadata | Melt operations | Payment correlation |

### 3.4 Low-Sensitivity Assets

| Asset | Location | Impact |
|-------|----------|--------|
| Mint public keys | Cached from NUT-01 | Public information |
| Keyset IDs | Proof metadata | Public information |
| Error messages | Logs | Potential info leak (mitigated by redaction) |

---

## 4. Adversary Models

### 4.1 Network Adversary
**Capabilities:** MITM positioning, traffic analysis, DNS manipulation
**Goals:** Token theft, transaction correlation, service disruption
**Assumed Power:** Cannot break TLS 1.3, cannot compromise platform RNG

### 4.2 Malicious Mint
**Capabilities:** Full control of mint server responses
**Goals:** Forge proofs, deny service, track users
**Assumed Power:** Cannot forge BDHKE signatures without private key

### 4.3 Local Attacker
**Capabilities:** File system access, process memory inspection, backup access
**Goals:** Extract mnemonics/seeds, steal proofs
**Assumed Power:** Cannot bypass Keychain access controls (iOS), may have root on jailbroken devices

### 4.4 Supply Chain Attacker
**Capabilities:** Modify dependencies, inject malicious code
**Goals:** Backdoor RNG, exfiltrate secrets
**Assumed Power:** Limited by code review, dependency pinning

### 4.5 Side-Channel Attacker
**Capabilities:** Timing analysis, cache attacks, power analysis
**Goals:** Extract key material during crypto operations
**Assumed Power:** Physical proximity or VM co-residency

---

## 5. STRIDE Threat Analysis

### 5.1 Spoofing

| ID | Threat | Component | Impact | Likelihood | Risk |
|----|--------|-----------|--------|------------|------|
| S1 | Mint impersonation via DNS hijack | NetworkRouter | HIGH | LOW | MEDIUM |
| S2 | OAuth token forgery | NUT-21 | HIGH | LOW | MEDIUM |
| S3 | Proof ownership spoofing | Token import | HIGH | LOW | MEDIUM |
| S4 | Keyset ID collision | NUT-02 | MEDIUM | VERY LOW | LOW |

**Mitigations:**
- **S1:** HTTPS required for all mint URLs; TLS pinning available as opt-in
- **S2:** JWT signature validation; OIDC discovery verification
- **S3:** Cryptographic signature verification via mint before acceptance
- **S4:** Keyset IDs are derived from key material (collision-resistant)

### 5.2 Tampering

| ID | Threat | Component | Impact | Likelihood | Risk |
|----|--------|-----------|--------|------------|------|
| T1 | Token modification in transit | Serialization | HIGH | LOW | MEDIUM |
| T2 | Storage file tampering | FileSecureStore | CRITICAL | MEDIUM | HIGH |
| T3 | Memory tampering (debug/JB) | Runtime | CRITICAL | LOW | MEDIUM |
| T4 | Counter manipulation | KeysetCounterStorage | MEDIUM | LOW | LOW |
| T5 | Proof state corruption | ProofManager | HIGH | LOW | MEDIUM |

**Mitigations:**
- **T1:** BDHKE signatures are cryptographically bound; tampering detected
- **T2:** AES-GCM authenticated encryption; POSIX 0o600 permissions
- **T3:** `SecureMemory.wipe()` best-effort; SensitiveData wrappers
- **T4:** Counters stored with same encryption as secrets
- **T5:** Actor isolation; atomic state transitions; rollback on failure

### 5.3 Repudiation

| ID | Threat | Component | Impact | Likelihood | Risk |
|----|--------|-----------|--------|------------|------|
| R1 | Double-spend attempt | Melt/Swap | HIGH | MEDIUM | HIGH |
| R2 | Transaction denial | Proof lifecycle | MEDIUM | LOW | LOW |
| R3 | Mint refuses valid payment | NUT-05 | MEDIUM | LOW | LOW |

**Mitigations:**
- **R1:** Proof state machine (available → pending → spent); atomic transitions
- **R2:** Local proof persistence; state tracking with timestamps
- **R3:** Payment proofs retained locally; can dispute with evidence

### 5.4 Information Disclosure

| ID | Threat | Component | Impact | Likelihood | Risk |
|----|--------|-----------|--------|------------|------|
| I1 | Mnemonic in logs | Observability | CRITICAL | LOW | MEDIUM |
| I2 | Proof secrets in logs | Observability | HIGH | LOW | MEDIUM |
| I3 | Memory residue after use | SecureMemory | HIGH | LOW | MEDIUM |
| I4 | Backup media exposure | Storage | CRITICAL | MEDIUM | HIGH |
| I5 | Side-channel key leakage | Crypto operations | CRITICAL | VERY LOW | LOW |
| I6 | Transaction correlation | Mint requests | MEDIUM | MEDIUM | MEDIUM |

**Mitigations:**
- **I1:** `SecretRedactor` patterns: mnemonic phrases, hex secrets
- **I2:** Redaction of "secret", "C", "witness" fields in logs
- **I3:** `SecureMemory.wipe()` in `SensitiveData.deinit`; multiple overwrite passes
- **I4:** FileSecureStore uses AES-GCM; Keychain uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
- **I5:** `SecureMemory.constantTimeCompare()` for signature verification
- **I6:** No correlation protection currently; future: blind token exchange

### 5.5 Denial of Service

| ID | Threat | Component | Impact | Likelihood | Risk |
|----|--------|-----------|--------|------------|------|
| D1 | Mint rate limiting wallet | Network | MEDIUM | MEDIUM | MEDIUM |
| D2 | Large payload attacks | Input parsing | LOW | MEDIUM | LOW |
| D3 | WebSocket connection flood | RobustWebSocketClient | LOW | LOW | LOW |
| D4 | Reconnection storms | WebSocketReconnection | LOW | LOW | LOW |
| D5 | Proof selection exhaustion | ProofManager | MEDIUM | LOW | LOW |

**Mitigations:**
- **D1:** `RateLimiter.swift` with token bucket algorithm
- **D2:** Max 1000 proofs/messages per request; payload size limits
- **D3:** Message queue limits; connection throttling
- **D4:** Exponential backoff with jitter; max retry limits
- **D5:** Efficient proof selection algorithm; indexed storage

### 5.6 Elevation of Privilege

| ID | Threat | Component | Impact | Likelihood | Risk |
|----|--------|-----------|--------|------------|------|
| E1 | Access token scope bypass | NUT-21/22 | HIGH | LOW | MEDIUM |
| E2 | P2PK timelock bypass | NUT-11 | HIGH | LOW | MEDIUM |
| E3 | HTLC preimage guessing | NUT-14 | HIGH | VERY LOW | LOW |
| E4 | Keyset confusion attack | Multi-mint | MEDIUM | LOW | LOW |

**Mitigations:**
- **E1:** Token scope validation; mint-specific token storage
- **E2:** Timelock validation against system time; server time comparison
- **E3:** Preimages are 32-byte random (256 bits entropy)
- **E4:** Keyset ID embedded in proof; validated on all operations

---

## 6. Data Flow Security Analysis

### 6.1 Minting Flow (NUT-04)

```
┌─────────┐    ┌──────────────┐    ┌──────────────┐    ┌─────────────┐
│  User   │───▶│  Validation  │───▶│   BDHKE      │───▶│   Network   │
│ (amount)│    │  Layer       │    │   Blinding   │    │   Request   │
└─────────┘    └──────────────┘    └──────────────┘    └─────────────┘
                                          │                    │
                   ┌──────────────────────┘                    │
                   ▼                                           ▼
            ┌──────────────┐                          ┌─────────────┐
            │ Secret Gen   │                          │ Mint Server │
            │ (SecureRandom)│                          │ (UNTRUSTED) │
            └──────────────┘                          └──────┬──────┘
                                                             │
┌─────────────┐    ┌──────────────┐    ┌──────────────┐      │
│   Storage   │◀───│   Unblind    │◀───│  Validation  │◀─────┘
│  (Proofs)   │    │   + Verify   │    │  (Response)  │
└─────────────┘    └──────────────┘    └──────────────┘
```

**Security Controls:**
1. `SecureRandom.generateBytes()` for secret generation
2. Blinding factor stored in ephemeral `WalletBlindingData`
3. Response validation: keyset match, amount match, signature verification
4. Proof storage after successful verification only
5. Blinding factor wiped after unblinding

### 6.2 Melting Flow (NUT-05)

```
┌─────────┐    ┌──────────────┐    ┌──────────────┐    ┌─────────────┐
│  User   │───▶│  Invoice     │───▶│   Proof      │───▶│   Mark      │
│(invoice)│    │  Validation  │    │  Selection   │    │   Pending   │
└─────────┘    └──────────────┘    └──────────────┘    └─────────────┘
                                                              │
                                                              ▼
                                                       ┌─────────────┐
                                                       │   Network   │
                                                       │   Request   │
                                                       └──────┬──────┘
                                                              │
┌─────────────┐    ┌──────────────┐    ┌──────────────┐      │
│   Finalize  │◀───│   Process    │◀───│   Response   │◀─────┘
│   or Roll   │    │   Result     │    │  Validation  │
│   back      │    └──────────────┘    └──────────────┘
└─────────────┘
```

**Security Controls:**
1. Invoice validation (format, amount bounds)
2. Proof selection with pending state marking (prevents double-spend)
3. Atomic commit: success → finalize (remove proofs), failure → rollback
4. Change proofs handled via swap (NUT-08)

### 6.3 Token Import Flow

```
┌─────────┐    ┌──────────────┐    ┌──────────────┐    ┌─────────────┐
│  User   │───▶│  Deserialize │───▶│   Validate   │───▶│   Check     │
│(token)  │    │  (V3/V4)     │    │   Structure  │    │   Duplicates│
└─────────┘    └──────────────┘    └──────────────┘    └─────────────┘
                                                              │
                                                              ▼
                                                       ┌─────────────┐
                                                       │   Verify    │
                                                       │   w/ Mint   │
                                                       └──────┬──────┘
                                                              │
┌─────────────┐    ┌──────────────┐                          │
│   Storage   │◀───│   Accept     │◀──────────────────────────┘
│  (Proofs)   │    │   Proofs     │
└─────────────┘    └──────────────┘
```

**Security Controls:**
1. Format detection and appropriate parser selection
2. Structure validation: required fields, valid types
3. Duplicate detection against existing proofs
4. Amount overflow checks (UInt64 bounds)
5. Mint verification before storage (optional, recommended)

---

## 7. Existing Security Controls

### 7.1 Cryptographic Controls

| Control | Location | Description |
|---------|----------|-------------|
| SecureRandom | `Utils/SecureRandom.swift` | CSPRNG via `SecRandomCopyBytes` (Apple) |
| Constant-time compare | `Security/SecureMemory.swift` | Timing-safe signature verification |
| Memory wiping | `Security/SecureMemory.swift` | Best-effort zeroization with SensitiveData wrapper |
| BDHKE implementation | `NUTs/NUT00.swift` | Blind Diffie-Hellman Key Exchange |
| BIP39 validation | `Utils/BIP39.swift` | Mnemonic generation and validation |

### 7.2 Storage Controls

| Control | Location | Description |
|---------|----------|-------------|
| Keychain storage | `SecureStorage/KeychainSecureStore.swift` | Apple Keychain with access controls |
| File encryption | `SecureStorage/FileSecureStore.swift` | AES-GCM with PBKDF2 key derivation |
| POSIX permissions | `FileSecureStore.hardenFile()` | 0o600 for files, 0o700 for directories |
| Access controls | Keychain attributes | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` |

### 7.3 Network Controls

| Control | Location | Description |
|---------|----------|-------------|
| Rate limiter | `Utils/RateLimiter.swift` | Token bucket algorithm |
| Circuit breaker | `Utils/CircuitBreaker.swift` | Failure isolation per endpoint |
| Request validation | `Core/NUTValidation.swift` | Input sanitization before network calls |
| TLS enforcement | `NetworkRouter` | HTTPS required for mint URLs |

### 7.4 Observability Controls

| Control | Location | Description |
|---------|----------|-------------|
| Secret redaction | `Observability/SecretRedactor.swift` | Pattern-based log sanitization |
| Structured logging | `Observability/StructuredLogger.swift` | Configurable log levels |
| Metrics collection | `Observability/MetricsCollector.swift` | Security event tracking |

---

## 8. Residual Risks & Recommendations

### 8.1 High Priority Recommendations

| ID | Risk | Current State | Recommendation | Effort |
|----|------|---------------|----------------|--------|
| H1 | JWT validation incomplete | Placeholder in NUT-21 | Implement full OIDC signature validation | Medium |
| H2 | Counter integrity | No integrity check | Add HMAC to counter storage | Low |
| H3 | TLS pinning optional | Available but not enforced | Document and recommend enabling | Low |
| H4 | Pending state timeout | No timeout | Add configurable timeout with auto-rollback | Medium |

### 8.2 Medium Priority Recommendations

| ID | Risk | Current State | Recommendation | Effort |
|----|------|---------------|----------------|--------|
| M1 | Memory wiping best-effort | Compiler may optimize away | Document limitation; consider mlockall | Low |
| M2 | Audit logging gaps | Partial coverage | Add security-relevant operation logging | Medium |
| M3 | Token backup encryption | Uses standard JSON | Add optional encrypted backup format | Medium |
| M4 | Proof freshness | No timestamp validation | Add mint timestamp verification | Low |

### 8.3 Low Priority Recommendations

| ID | Risk | Current State | Recommendation | Effort |
|----|------|---------------|----------------|--------|
| L1 | HSM support | Not implemented | Add Secure Enclave key operations (Apple) | High |
| L2 | Token binding | Not implemented | Add device binding option | High |
| L3 | Privacy enhancing | Basic privacy | Consider blind token exchange protocols | High |

---

## 9. Security Testing Requirements

### 9.1 Unit Tests (Implemented)

- [x] BDHKE correctness tests
- [x] BIP39 generation/validation tests
- [x] Proof state machine tests
- [x] Input validation tests
- [x] Constant-time comparison tests
- [x] Memory wiping tests

### 9.2 Integration Tests (Partial)

- [x] Token serialization round-trip
- [x] Proof selection algorithms
- [ ] Full mint/melt flows with mock server
- [ ] Network failure recovery

### 9.3 Security Tests (Recommended)

- [ ] Fuzz testing for token deserialization
- [ ] Property-based tests for crypto operations
- [ ] Concurrency stress tests for state machines
- [ ] Timing analysis for signature verification

---

## 10. Incident Response Triggers

| Event | Detection | Response |
|-------|-----------|----------|
| Multiple signature failures | MetricsCollector alert | Investigate mint key rotation; notify user |
| Rapid proof depletion | Balance change alerts | Review transaction log; possible theft |
| Repeated auth failures | Login attempt metrics | Rate limit; require re-authentication |
| Storage integrity failure | Decryption errors | Attempt recovery; notify user |
| Unexpected keyset IDs | Validation failures | Quarantine proofs; verify mint |

---

## 11. Compliance Considerations

### 11.1 Data Protection
- Mnemonic/seed treated as highest sensitivity (PII equivalent)
- Transaction data may be subject to financial regulations
- Logs sanitized to prevent accidental exposure

### 11.2 Cryptographic Standards
- Uses established libraries: secp256k1, CryptoSwift
- PBKDF2 with 100,000 rounds for key derivation
- AES-256-GCM for symmetric encryption

### 11.3 Platform Requirements
- Apple platforms: Keychain APIs, app sandbox
- Linux: File permissions, process isolation
- All: HTTPS enforcement, certificate validation

---

## Appendix A: Threat Matrix Summary

| Category | Critical | High | Medium | Low | Total |
|----------|----------|------|--------|-----|-------|
| Spoofing | 0 | 2 | 2 | 0 | 4 |
| Tampering | 2 | 2 | 1 | 0 | 5 |
| Repudiation | 0 | 1 | 2 | 0 | 3 |
| Info Disclosure | 2 | 2 | 2 | 0 | 6 |
| Denial of Service | 0 | 0 | 2 | 3 | 5 |
| Elevation | 0 | 2 | 2 | 0 | 4 |
| **Total** | **4** | **9** | **11** | **3** | **27** |

## Appendix B: Version History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-09-22 | - | Initial draft outline |
| 2.0 | 2025-12-29 | - | Complete STRIDE analysis, data flows, recommendations |

---

*This document should be reviewed quarterly and updated when significant changes occur to the codebase or threat landscape.*
