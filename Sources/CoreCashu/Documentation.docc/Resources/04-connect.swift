import CoreCashu

// Create wallet configuration pointing to a Cashu mint
let config = WalletConfiguration(
    mintURL: "https://testnut.cashu.space",
    unit: .sat
)

// Initialize the wallet with the configuration
let wallet = await CashuWallet(configuration: config)

// Connect to the mint and sync keysets
try await wallet.initialize()

// Check the wallet balance
let balance = try await wallet.balance
print("Current balance: \(balance) sats")
