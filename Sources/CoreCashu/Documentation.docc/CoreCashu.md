# ``CoreCashu``

Internal Swift implementation of the Cashu protocol. This library provides the core cryptographic operations and protocol implementation used by CashuKit.

## Overview

CoreCashu is the foundational layer that implements the Cashu protocol specification. It handles blind signatures, mint interactions, and all NUT (Notation, Usage, and Terminology) implementations.

> Note: **End users should use CashuKit** for Apple platform development. CoreCashu is an internal library used by CashuKit and swift-cashu-mint.

## Topics

### Core Types

- ``CashuWallet``
- ``WalletConfiguration``
- ``Proof``
- ``CashuToken``

### Protocol Implementation

- ``MintFeatureCapability``
- ``MintFeatureCapabilityManager``
- ``WalletStateMachine``
- ``MultiPathPaymentExecutor``

### Security

- ``SecureStore``
- ``FileSecureStore``
- ``SecureMemory``
- ``SecureRandom``

### Error Handling

- ``CashuError``
- ``UserFriendlyError``

## Protocol Compliance

CoreCashu implements the following Cashu NUTs:

| NUT | Description | Status |
|-----|-------------|--------|
| 00 | Cryptography and Models | Complete |
| 01 | Mint public keys | Complete |
| 02 | Keysets and keyset IDs | Complete |
| 03 | Swap tokens | Complete |
| 04 | Mint tokens | Complete |
| 05 | Melt tokens | Complete |
| 06 | Mint info | Complete |
| 07 | Token state check | Complete |
| 08 | Overpaid Lightning fees | Complete |
| 09 | Restore signatures | Complete |
| 10 | Spending conditions | Complete |
| 11 | Pay to Public Key (P2PK) | Complete |
| 12 | DLEQ proofs | Complete |
| 13 | Deterministic secrets | Complete |

## Security Documentation

Security auditors should review the following documents in `CoreCashu/Docs/`:

- `threat_model.md` - STRIDE threat analysis
- `security_assumptions.md` - Trust boundaries and assumptions
- `audit_scope.md` - Security-critical code paths
- `static_analysis_report.md` - Analysis findings

## See Also

- [Cashu Protocol Specification](https://github.com/cashubtc/nuts)
- [Cashu Documentation](https://docs.cashu.space)