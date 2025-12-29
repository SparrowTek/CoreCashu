# Security

Understand CoreCashu's security model and best practices for secure integration.

## Overview

CoreCashu implements comprehensive security measures for handling ecash. This document
covers the security architecture, assumptions, and recommendations for production use.

## Security Features

### Cryptographic Security

CoreCashu uses established cryptographic primitives:

- **BDHKE**: Blind Diffie-Hellman Key Exchange for token privacy
- **secp256k1**: Elliptic curve cryptography via `swift-secp256k1`
- **AES-GCM**: Authenticated encryption for secure storage
- **PBKDF2**: Key derivation with 200,000 iterations

All random number generation uses platform CSPRNGs:
- Apple: `SecRandomCopyBytes`
- Linux: `/dev/urandom`

### Constant-Time Operations

Sensitive comparisons use constant-time algorithms to prevent timing attacks:

```swift
// Use this for comparing secrets
let equal = SecureMemory.constantTimeCompare(a, b)

// NOT this
let wrong = a == b // Vulnerable to timing attacks
```

### Memory Protection

Sensitive data is automatically zeroized when no longer needed:

```swift
let sensitive = SensitiveData(secretKey)
// Use sensitive data...
sensitive.wipe() // Securely zeroes memory
```

The ``SensitiveData`` and ``SensitiveString`` wrappers automatically wipe on deallocation.

### Secure Storage

#### Apple Platforms (via CashuKit)

- Mnemonics and seeds stored in Keychain
- Optional biometric protection (Face ID / Touch ID)
- Secure Enclave support for key operations

#### Linux/Server

``FileSecureStore`` provides:
- AES-GCM envelope encryption
- Master key rotation support
- Strict file permissions (0600)
- Optional password-derived keys

```swift
let store = try FileSecureStore(
    directory: dataDir,
    password: "user-password" // Optional additional protection
)
```

### Network Security

#### Rate Limiting

Prevents overwhelming mints with requests:

```swift
// Automatically applied to all mint requests
// Default: 60 requests per minute with burst of 10
```

#### Circuit Breaker

Prevents cascading failures:

```swift
// Opens after 5 failures, half-opens after 30 seconds
// Automatically applied to mint endpoints
```

## Security Assumptions

### Platform Trust

CoreCashu trusts the underlying platform for:

1. **CSPRNG**: Platform random number generators are cryptographically secure
2. **TLS**: Platform TLS implementation is correct and up-to-date
3. **Memory**: Platform provides basic memory protection
4. **Storage**: Platform storage APIs work as documented

### Mint Trust Model

The Cashu protocol has an inherent trust relationship with mints:

**What mints CAN do:**
- Observe all transactions (amounts, timing)
- Refuse to redeem tokens (censorship)
- Issue tokens without backing (inflation)

**What mints CANNOT do:**
- Link sender to receiver (if tokens are swapped)
- Forge tokens without the private key
- Spend user tokens without possession

### What CoreCashu Protects Against

- **Token theft**: Encrypted storage, memory zeroization
- **Timing attacks**: Constant-time comparisons
- **Network failures**: Rate limiting, circuit breakers
- **State corruption**: Actor isolation, transactional proof management

### What CoreCashu Does NOT Protect Against

- **Compromised device**: If the device is compromised, keys may be extracted
- **Malicious mints**: Cannot prevent mint from refusing redemption
- **Physical access**: Side-channel attacks with physical access

## Best Practices

### For Application Developers

1. **Enable biometric authentication** on Apple platforms
2. **Use strong passwords** for FileSecureStore on Linux
3. **Monitor for failed operations** and alert users
4. **Implement proper backup procedures** for mnemonics
5. **Use secure communication** when sharing tokens

### For Production Deployments

1. **Await security audit** before handling significant funds
2. **Keep dependencies updated** for security patches
3. **Monitor circuit breaker** states for mint health
4. **Implement rate limiting** on your application layer too
5. **Use hardware security modules** where available

## Audit Status

CoreCashu has completed internal security hardening:

- 660+ tests passing
- BIP32/BIP39 verified against official test vectors
- No force unwraps or unsafe patterns
- All `@unchecked Sendable` audited

**External security audit is pending.** Production use with significant funds should await audit completion.

See the full security documentation in the `Docs/` directory:
- `threat_model.md` - STRIDE analysis
- `security_assumptions.md` - Platform trust model
- `audit_scope.md` - Security-critical code paths

## See Also

- ``SecureStore``
- ``SecureMemory``
- ``SecureRandom``
- ``FileSecureStore``
