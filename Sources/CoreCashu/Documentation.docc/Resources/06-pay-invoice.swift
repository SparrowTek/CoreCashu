import CoreCashu

// Request a mint quote for 1000 sats
let quote = try await wallet.requestMintQuote(amount: 1000, method: .bolt11)

// Display the Lightning invoice to pay
print("Pay this invoice: \(quote.request)")
print("Quote ID: \(quote.quote)")

// The user pays the Lightning invoice using their Lightning wallet
// This happens outside of CoreCashu - the user pays the invoice

// Check if the invoice has been paid
let quoteStatus = try await wallet.checkMintQuoteStatus(quoteId: quote.quote)
print("Payment status: \(quoteStatus.state)")
