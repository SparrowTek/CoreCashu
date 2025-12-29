# CoreCashu Security Assumptions

> **Status:** Complete - December 29, 2025
> **Version:** 1.0

## Overview

This document explicitly states the security assumptions underlying CoreCashu's design. Understanding these assumptions is critical for:
- Security auditors evaluating the codebase
- Developers integrating CoreCashu into applications
- Operators deploying systems using CoreCashu

Violations of these assumptions may lead to security failures that CoreCashu cannot protect against.

---

## 1. Platform Trust

### 1.1 What We Trust

| Component | Assumption | Consequence if Violated |
|-----------|------------|------------------------|
| **Platform CSPRNG** | `SecRandomCopyBytes` (Apple) and `SystemRandomNumberGenerator` (Linux) provide cryptographically secure randomness | Key compromise, secret prediction |
| **TLS Stack** | Platform TLS implementation correctly validates certificates and provides confidentiality/integrity | MITM attacks, credential theft |
| **Keychain (Apple)** | iOS/macOS Keychain provides secure storage with access controls | Mnemonic/seed exposure |
| **File System Permissions** | POSIX permissions (0o600/0o700) are enforced by the OS | Unauthorized file access |
| **Process Isolation** | Operating system enforces process memory isolation | Cross-process secret leakage |
| **System Clock** | System time is reasonably accurate (within minutes) | Timelock bypass (NUT-11), token expiry issues |

### 1.2 Platform-Specific Notes

**iOS/macOS:**
- Keychain items use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
- Jailbroken devices may not enforce Keychain protections
- App sandbox provides additional isolation

**Linux:**
- Relies on filesystem permissions for secret protection
- No hardware-backed secure storage by default
- Process isolation depends on deployment environment

**WASM (Future):**
- No persistent secure storage available
- Secrets must be provided per-session
- Additional isolation needed at integration layer

---

## 2. Network Trust

### 2.1 What We Do NOT Trust

| Component | Assumption | Protection Mechanism |
|-----------|------------|---------------------|
| **Network Transport** | May be monitored, intercepted, or manipulated | TLS encryption required; HTTPS enforced for mint URLs |
| **DNS Resolution** | May be poisoned or hijacked | URL validation; optional TLS pinning |
| **Mint Server** | May be malicious, compromised, or unavailable | Cryptographic verification of all responses; circuit breaker for failures |
| **Response Content** | May contain hostile payloads | Input validation; size limits; parser hardening |
| **WebSocket Messages** | May be replayed or injected | Stateful session tracking; message validation |

### 2.2 Mint Trust Model

CoreCashu's security model for mints:

```
TRUST LEVEL: Partial Trust with Verification

- We TRUST mints to:
  * Follow the Cashu protocol specification
  * Hold backing funds for issued tokens (economic assumption)
  * Respond to protocol requests in reasonable time
  
- We DO NOT TRUST mints to:
  * Protect our privacy (mints see blinded messages)
  * Not track our transactions (correlation possible)
  * Provide truthful metadata (verify via cryptography)
  * Be available (handle offline scenarios)
  
- We VERIFY:
  * All blind signatures against mint public keys
  * Keyset IDs match expected values
  * Response formats match protocol specification
  * State transitions are cryptographically valid
```

### 2.3 TLS Requirements

| Requirement | Status | Notes |
|-------------|--------|-------|
| TLS 1.2+ required | Enforced | Via platform defaults |
| Certificate validation | Platform default | Standard CA verification |
| Certificate pinning | Optional | Available for high-security deployments |
| HTTP prohibited | Enforced | Mint URLs must be HTTPS |

---

## 3. Cryptographic Assumptions

### 3.1 Primitive Security

| Primitive | Assumption | Library |
|-----------|------------|---------|
| **secp256k1** | ECDLP is computationally hard | swift-secp256k1 |
| **SHA-256** | Collision resistance, preimage resistance | CryptoSwift |
| **AES-256-GCM** | Provides authenticated encryption | CryptoSwift |
| **PBKDF2-SHA256** | Key derivation is computationally expensive | CryptoSwift |
| **BIP39** | Mnemonic entropy is sufficient (128-256 bits) | Custom implementation |
| **Hash-to-curve** | secp256k1 hash-to-curve is secure | Custom (per BIP-340) |

### 3.2 Protocol Assumptions

| Protocol | Assumption | Specification |
|----------|------------|---------------|
| **BDHKE** | Blind Diffie-Hellman Key Exchange is unforgeable | NUT-00 |
| **DLEQ** | Discrete Log Equality proofs are sound | NUT-12 |
| **P2PK** | Schnorr signatures are secure | NUT-11 (BIP-340) |
| **HTLC** | SHA-256 preimages are computationally hidden | NUT-14 |

### 3.3 Key Derivation

```
TRUST: Deterministic derivation is secure when:
  1. Mnemonic has sufficient entropy (128+ bits)
  2. PBKDF2 uses adequate rounds (100,000)
  3. Derived secrets are unique per context

ASSUMPTION: BIP32/BIP39 derivation paths provide:
  - Collision resistance between wallets
  - Unpredictability of child keys from parent
  - Independence between derived secrets
```

---

## 4. Storage Assumptions

### 4.1 Secret Storage Requirements

| Secret Type | Storage Mechanism | Access Control |
|-------------|-------------------|----------------|
| Mnemonic | Keychain (Apple) / Encrypted file (Linux) | User presence optional |
| Seed | Keychain (Apple) / Encrypted file (Linux) | User presence optional |
| Access Tokens | Keychain (Apple) / Encrypted file (Linux) | After first unlock |
| Proofs | In-memory by default | Application-controlled |

### 4.2 FileSecureStore Assumptions

```
ASSUMPTION: AES-GCM encryption provides:
  - Confidentiality against file system access
  - Integrity verification on read
  - Unique nonce per encryption

ASSUMPTION: POSIX permissions provide:
  - Read/write restriction to owner
  - Protection in multi-user environments
  - NOT protection against root/admin

LIMITATION: File encryption key may be derived from:
  - User-provided password (recommended)
  - Random key stored in same directory (less secure)
```

### 4.3 Keychain (Apple) Assumptions

```
ASSUMPTION: Keychain provides:
  - Hardware-backed encryption (Secure Enclave where available)
  - Access control policy enforcement
  - App-scoped isolation

LIMITATION: Keychain protection is weakened on:
  - Jailbroken devices
  - macOS with weak login password
  - Devices without Secure Enclave
```

---

## 5. Operational Assumptions

### 5.1 Deployment Requirements

| Requirement | Rationale |
|-------------|-----------|
| Secure boot chain | Prevents tampering with runtime environment |
| Up-to-date OS | Security patches for platform vulnerabilities |
| Process isolation | Prevents cross-process secret access |
| Secure network | TLS inspection proxies may break security model |

### 5.2 Application Responsibilities

CoreCashu assumes the integrating application will:

| Responsibility | Why |
|----------------|-----|
| Protect mnemonic input | CoreCashu cannot secure keyboard input |
| Secure backup procedures | Mnemonic backup is application's responsibility |
| Implement user authentication | CoreCashu provides no user auth |
| Handle key rotation | Application decides when to rotate |
| Monitor for anomalies | Application has user context |
| Implement recovery procedures | Application knows user's identity |

### 5.3 What CoreCashu Does NOT Provide

| Feature | Status | Notes |
|---------|--------|-------|
| User authentication | Not provided | Use platform biometrics via CashuKit |
| Account recovery | Not provided | Mnemonic is the only recovery method |
| Transaction privacy | Limited | Mints can correlate transactions |
| Offline sending | Not provided | Requires mint connectivity |
| Multi-sig wallets | Not provided | Future consideration |

---

## 6. Threat Mitigation Boundaries

### 6.1 What CoreCashu Protects Against

| Threat | Protection |
|--------|------------|
| Token forgery | BDHKE signatures verified against mint keys |
| Double-spend by wallet | Proof state machine prevents local double-spend |
| Network eavesdropping | TLS encryption for all mint communications |
| Storage theft (basic) | AES-GCM encryption, file permissions |
| Log leakage | Secret redaction in all logging |
| Timing attacks | Constant-time comparison for signatures |
| Input injection | Validation on all external inputs |

### 6.2 What CoreCashu Does NOT Protect Against

| Threat | Why | Mitigation Approach |
|--------|-----|---------------------|
| Compromised device | Cannot protect against OS/hardware compromise | Use device security features |
| Malware with root access | Cannot protect against privileged attackers | OS-level security |
| Physical device theft | Cannot prevent physical access | Device encryption, biometrics |
| Social engineering | Cannot verify user identity | User education |
| Mint exit scam | Cannot prevent mint from running away | Multiple mints, small balances |
| Supply chain attacks | Limited control over dependencies | Dependency review, pinning |
| Quantum computing | Current crypto not quantum-resistant | Future protocol updates |

---

## 7. Dependency Trust

### 7.1 Direct Dependencies

| Dependency | Purpose | Trust Level |
|------------|---------|-------------|
| swift-secp256k1 | Elliptic curve operations | High - well-audited upstream |
| CryptoSwift | Symmetric crypto, hashing | Medium - widely used |
| BigInt | Large number arithmetic | Medium - mature library |

### 7.2 Dependency Security Policy

```
ASSUMPTION: Dependencies are:
  - Obtained from official sources (SPM)
  - Pinned to specific versions
  - Reviewed for security-relevant changes
  - Updated for security patches

RESPONSIBILITY: Integrators should:
  - Monitor dependency vulnerabilities
  - Test updates before deployment
  - Consider vendoring critical dependencies
```

---

## 8. Concurrency Assumptions

### 8.1 Thread Safety Model

```
ASSUMPTION: Swift actors provide:
  - Data race prevention for actor-isolated state
  - Sequential access to actor properties
  - Safe async/await interleaving

ENFORCEMENT:
  - CashuWallet is an actor
  - ProofManager operations are atomic
  - Storage operations are synchronized
```

### 8.2 State Machine Integrity

```
ASSUMPTION: Proof state transitions are:
  - Atomic (all-or-nothing)
  - Serializable (no concurrent mutation)
  - Recoverable (rollback on failure)

STATE MACHINE:
  Available → Pending → Spent (success)
           ↘         ↗
            → Rollback (failure)
```

---

## 9. Failure Mode Assumptions

### 9.1 Graceful Degradation

| Failure | Expected Behavior |
|---------|-------------------|
| Network unavailable | Operations fail with error; state preserved |
| Mint unreachable | Circuit breaker opens; cached data used where safe |
| Storage failure | Operations fail; in-memory state preserved |
| Invalid response | Rejected; no state change |

### 9.2 Recovery Assumptions

```
ASSUMPTION: Wallet recovery via mnemonic will:
  - Restore all deterministically-derived secrets
  - NOT restore randomly-generated proofs (lost)
  - Require mint connectivity for restoration
  - Take time proportional to number of keysets
```

---

## 10. Audit Checklist

Auditors should verify:

- [ ] CSPRNG usage is correctly implemented
- [ ] TLS certificate validation is enabled
- [ ] Keychain/storage access controls are appropriate
- [ ] Input validation covers all external inputs
- [ ] Secrets are not logged (verify redaction)
- [ ] Memory is wiped after sensitive operations
- [ ] Actor isolation prevents data races
- [ ] Error handling doesn't leak information
- [ ] Dependencies are from trusted sources
- [ ] State machine transitions are atomic

---

## Appendix: Assumption Violation Reporting

If you identify a violation of these assumptions in production code, please:

1. **Do not disclose publicly** until a fix is available
2. Report via the project's security policy
3. Provide a proof-of-concept if possible
4. Allow reasonable time for remediation

---

*Last Updated: December 29, 2025*
