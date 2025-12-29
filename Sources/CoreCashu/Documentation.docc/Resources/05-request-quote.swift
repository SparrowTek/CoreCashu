import CoreCashu

// Request a mint quote for 1000 sats
let quote = try await wallet.requestMintQuote(amount: 1000, method: .bolt11)

// Display the Lightning invoice to pay
print("Pay this invoice: \(quote.request)")
print("Quote ID: \(quote.quote)")
