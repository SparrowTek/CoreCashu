import CoreCashu

// Request a mint quote for 1000 sats
let quote = try await wallet.requestMintQuote(amount: 1000, method: .bolt11)

// Display the Lightning invoice to pay
print("Pay this invoice: \(quote.request)")
print("Quote ID: \(quote.quote)")

// The user pays the Lightning invoice using their Lightning wallet

// Once paid, mint the tokens
let mintResult = try await wallet.mint(
    amount: 1000,
    quoteId: quote.quote,
    method: .bolt11
)

// New proofs are now in the wallet
print("Minted \(mintResult.newProofs.count) proofs")
print("Total amount: \(mintResult.newProofs.reduce(0) { $0 + $1.amount }) sats")
