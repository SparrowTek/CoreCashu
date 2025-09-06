# ``CoreCashu``

A comprehensive Swift implementation of the Cashu protocol for building privacy-preserving eCash wallets and applications.

## Overview

CoreCashu provides a complete implementation of the Cashu protocol, enabling developers to build applications that use Chaumian eCash for private, instant, and low-fee Bitcoin transactions. This library handles all the cryptographic operations, mint interactions, and protocol compliance required by the Cashu specification.

### Key Features

- **Complete Protocol Support**: Implements all essential Cashu NUTs (Notation, Usage, and Terminology specifications)
- **Privacy-First**: Utilizes blind signatures to ensure transaction privacy
- **Cross-Platform**: Works on macOS, iOS, Linux, and other Swift-supported platforms
- **Type-Safe**: Leverages Swift's type system for safe and reliable code
- **Modern Concurrency**: Built with Swift's async/await and actor model for thread-safe operations

## Topics

### Essentials

- ``CashuWallet``
- ``WalletConfiguration``
- ``Proof``
- ``CashuToken``

### Protocol Support (NUTs)

- <doc:NUT00-CryptoConditions>
- <doc:NUT01-MintInfo>
- <doc:NUT02-Keysets>
- <doc:NUT03-SwapTokens>
- <doc:NUT04-MintTokens>
- <doc:NUT05-MeltTokens>
- <doc:NUT06-MintInformation>
- <doc:NUT07-StateCheck>
- <doc:NUT09-Restore>
- <doc:NUT10-SecretTypes>
- <doc:NUT11-P2PK>
- <doc:NUT12-DLEQProofs>
- <doc:NUT13-DeterministicSecrets>

### Advanced Features

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

## Getting Started

### Creating a Wallet

The main entry point for interacting with Cashu mints is the ``CashuWallet`` actor:

```swift
import CoreCashu

// Create wallet configuration
let config = WalletConfiguration(
    mintURL: "https://mint.example.com",
    unit: .sat
)

// Initialize the wallet
let wallet = await CashuWallet(configuration: config)

// Initialize connection to mint
try await wallet.initializeWallet()
```

### Minting Tokens

To create new eCash tokens from a Lightning invoice:

```swift
// Request a mint quote
let quote = try await wallet.requestMintQuote(amount: 1000)

// Pay the Lightning invoice...
// Then mint tokens once payment is confirmed
let proofs = try await wallet.mint(quote: quote)
```

### Sending Tokens

Create a token that can be sent to another user:

```swift
// Create a sendable token
let token = try await wallet.send(amount: 100)

// The token string can be shared
print("Send this token: \(token)")
```

### Receiving Tokens

Process a received token:

```swift
// Receive and swap the token
let proofs = try await wallet.receive(token: tokenString)
print("Received \(proofs.totalAmount) sats")
```

### Checking Token State

Verify if tokens are spent or unspent:

```swift
// Check if wallet supports state checking
if wallet.isCapabilitySupported(.stateCheck) {
    let states = try await wallet.checkProofStates(proofs)
    for state in states {
        print("Proof state: \(state)")
    }
}
```

## Protocol Compliance

CoreCashu implements the following Cashu NUTs (specifications):

| NUT | Description | Status |
|-----|-------------|--------|
| 00 | Cryptography and Models | ✅ Complete |
| 01 | Mint public keys | ✅ Complete |
| 02 | Keysets and keyset IDs | ✅ Complete |
| 03 | Swap tokens | ✅ Complete |
| 04 | Mint tokens | ✅ Complete |
| 05 | Melt tokens | ✅ Complete |
| 06 | Mint info | ✅ Complete |
| 07 | Token state check | ✅ Complete |
| 08 | Overpaid Lightning fees | ✅ Complete |
| 09 | Restore signatures | ✅ Complete |
| 10 | Spending conditions | ✅ Complete |
| 11 | Pay to Public Key (P2PK) | ✅ Complete |
| 12 | DLEQ proofs | ✅ Complete |
| 13 | Deterministic secrets | ✅ Complete |

## Security Considerations

CoreCashu implements several security best practices:

- **Secure Random Generation**: Uses platform-specific cryptographically secure random number generators
- **Memory Protection**: Implements secure memory wiping for sensitive data
- **Secure Storage**: Provides encrypted storage options for keys and tokens
- **No Logging of Secrets**: Ensures private keys and sensitive data are never logged

For detailed security information, see the [Security Documentation](https://github.com/cashubtc/nuts/blob/main/SECURITY.md).

## Requirements

- Swift 6.0 or later
- macOS 15.0+ / iOS 17.0+ / Linux
- Dependencies:
  - swift-secp256k1
  - CryptoSwift
  - BigInt

## See Also

- [Cashu Protocol Specification](https://github.com/cashubtc/nuts)
- [Cashu.space](https://docs.cashu.space)
- ``CashuKit`` - Apple platform-specific extensions