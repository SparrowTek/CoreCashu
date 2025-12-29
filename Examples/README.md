# CoreCashu Examples

This directory contains example code demonstrating how to use CoreCashu for various wallet operations.

## Examples

### [BasicWalletSetup.swift](BasicWalletSetup.swift)
- Creating wallets for different platforms (Apple, Linux, test)
- Setting up deterministic wallets with mnemonics
- Multi-mint wallet management
- Custom logging configuration

### [MintingTokens.swift](MintingTokens.swift)
- Requesting mint quotes
- Polling for payment confirmation
- Minting tokens after payment
- Error handling for minting operations

### [SendingReceiving.swift](SendingReceiving.swift)
- Sending tokens to another user
- Receiving tokens from others
- Token inspection and validation
- Checking token state (spent/unspent)
- Batch send/receive operations

### [MeltingTokens.swift](MeltingTokens.swift)
- Paying Lightning invoices with tokens
- Estimating melt fees
- Handling fee change (NUT-08)
- Error handling for payment failures

### [WalletRestore.swift](WalletRestore.swift)
- Generating BIP39 mnemonics
- Validating mnemonic phrases
- Restoring wallets from seed
- Multi-mint restoration

## Quick Start

```swift
import CoreCashu

// 1. Create a wallet
let config = WalletConfiguration(
    mintURL: "https://testnut.cashu.space",
    unit: .sat
)
let wallet = await CashuWallet(configuration: config)
try await wallet.initialize()

// 2. Check balance
let balance = try await wallet.balance
print("Balance: \(balance) sats")

// 3. Send tokens
let token = try await wallet.send(amount: 100)
print("Token: \(try token.serialize())")

// 4. Receive tokens
let proofs = try await wallet.receive(token: tokenString)
print("Received \(proofs.count) proofs")
```

## Platform-Specific Setup

### Apple Platforms (iOS/macOS)

Use CashuKit for Keychain integration:

```swift
import CashuKit

let wallet = await AppleCashuWallet()
try await wallet.connect(to: URL(string: "https://mint.example.com")!)
```

### Linux/Server

Use FileSecureStore for encrypted storage:

```swift
import CoreCashu

let secureStore = try FileSecureStore(
    directory: dataDir,
    password: "secure-password"
)

let wallet = await CashuWallet(
    configuration: config,
    secureStore: secureStore
)
```

## Notes

- These examples are for demonstration purposes
- Some API calls may need adjustment based on the actual wallet state
- Always validate mnemonics before using them
- Production use should await security audit completion
