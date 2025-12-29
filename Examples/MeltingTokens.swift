/// # Melting Tokens
///
/// This example demonstrates how to melt Cashu tokens to pay Lightning invoices.

import CoreCashu
import Foundation

// MARK: - Basic Melting Flow

/// Melt tokens to pay a Lightning invoice
func meltTokens(wallet: CashuWallet, invoice: String) async throws {
    // Step 1: Request a melt quote
    let quote = try await wallet.requestMeltQuote(
        request: invoice,
        method: .bolt11
    )
    
    print("Amount to pay: \(quote.amount) sats")
    print("Fee reserve: \(quote.feeReserve) sats")
    print("Total required: \(quote.amount + quote.feeReserve) sats")
    
    // Check if we have enough balance
    let balance = try await wallet.balance
    let totalNeeded = quote.amount + quote.feeReserve
    
    guard balance >= totalNeeded else {
        print("Insufficient balance: have \(balance), need \(totalNeeded)")
        return
    }
    
    // Step 2: Melt the tokens
    let result = try await wallet.melt(
        request: invoice,
        method: .bolt11
    )
    
    if result.paid {
        print("Payment successful!")
        print("Payment preimage: \(result.paymentPreimage ?? "none")")
        
        // Check for fee change (NUT-08)
        if let change = result.change, !change.isEmpty {
            let changeAmount = change.reduce(0) { $0 + $1.amount }
            print("Fee change returned: \(changeAmount) sats")
        }
    } else {
        print("Payment failed or pending")
    }
}

// MARK: - Melt with Fee Estimation

/// Get a quote to estimate fees before melting
func estimateMeltFee(wallet: CashuWallet, invoice: String) async throws {
    let quote = try await wallet.requestMeltQuote(
        request: invoice,
        method: .bolt11
    )
    
    print("Invoice amount: \(quote.amount) sats")
    print("Fee reserve: \(quote.feeReserve) sats")
    print("Estimated total: \(quote.amount + quote.feeReserve) sats")
    
    // The actual fee may be lower - you get change back
    print("\nNote: Actual fee may be lower. Unused fee reserve is returned as change.")
}

// MARK: - Checking Melt Quote Status

/// Check the status of a melt operation
func checkMeltStatus(wallet: CashuWallet, quoteId: String) async throws {
    let status = try await wallet.checkMeltQuoteStatus(quoteId: quoteId)
    
    print("Quote ID: \(quoteId)")
    print("State: \(status.state)")
    print("Paid: \(status.paid)")
    
    if let preimage = status.paymentPreimage {
        print("Payment preimage: \(preimage)")
    }
}

// MARK: - Error Handling

/// Melt with comprehensive error handling
func safeMelt(wallet: CashuWallet, invoice: String) async throws {
    do {
        // Get quote
        let quote = try await wallet.requestMeltQuote(
            request: invoice,
            method: .bolt11
        )
        
        // Verify balance
        let balance = try await wallet.balance
        let needed = quote.amount + quote.feeReserve
        
        guard balance >= needed else {
            throw CashuError.insufficientBalance(required: needed, available: balance)
        }
        
        // Execute melt
        let result = try await wallet.melt(
            request: invoice,
            method: .bolt11
        )
        
        if result.paid {
            print("Payment successful!")
        } else {
            print("Payment may still be pending")
        }
        
    } catch let error as CashuError {
        switch error {
        case .insufficientBalance(let required, let available):
            print("Insufficient balance: need \(required), have \(available)")
            
        case .invoiceExpired:
            print("The Lightning invoice has expired")
            
        case .invoiceAlreadyPaid:
            print("This invoice has already been paid")
            
        case .paymentFailed(let reason):
            print("Payment failed: \(reason)")
            // Proofs should be returned to wallet
            
        case .networkError(let underlying):
            print("Network error: \(underlying.localizedDescription)")
            // Should retry the quote status check
            
        default:
            print("Error: \(error.localizedDescription)")
        }
    }
}

// MARK: - Fee Change (NUT-08)

/// Handle fee change after melting
func handleFeeChange(meltResult: MeltResult, wallet: CashuWallet) async throws {
    if meltResult.paid {
        print("Payment successful")
        
        // Check for returned fee change
        if let change = meltResult.change, !change.isEmpty {
            let changeAmount = change.reduce(0) { $0 + $1.amount }
            print("Fee change returned: \(changeAmount) sats")
            
            // Change proofs are automatically added to wallet
            let newBalance = try await wallet.balance
            print("New balance: \(newBalance) sats")
        }
    }
}

// MARK: - Paying BOLT11 Invoices

/// Parse and validate a BOLT11 invoice before paying
func payInvoice(wallet: CashuWallet, invoice: String) async throws {
    // Get the melt quote to see invoice details
    let quote = try await wallet.requestMeltQuote(
        request: invoice,
        method: .bolt11
    )
    
    print("Invoice details:")
    print("  Amount: \(quote.amount) sats")
    print("  Fee reserve: \(quote.feeReserve) sats")
    print("  Expiry: \(quote.expiry ?? 0)")
    
    // Check balance
    let balance = try await wallet.balance
    let needed = quote.amount + quote.feeReserve
    
    if balance >= needed {
        print("\nSufficient balance. Proceeding with payment...")
        
        let result = try await wallet.melt(
            request: invoice,
            method: .bolt11
        )
        
        if result.paid {
            print("Payment successful!")
            if let preimage = result.paymentPreimage {
                print("Preimage: \(preimage)")
            }
        }
    } else {
        print("\nInsufficient balance:")
        print("  Have: \(balance) sats")
        print("  Need: \(needed) sats")
        print("  Short: \(needed - balance) sats")
    }
}

// MARK: - MPP Support (NUT-15)

/// Check if mint supports multi-path payments
func checkMPPSupport(wallet: CashuWallet) async throws {
    let info = try await wallet.getMintInfo()
    
    if let nut15 = info.nuts?["15"] {
        print("Mint supports Multi-Path Payments (NUT-15)")
        print("NUT-15 config: \(nut15)")
    } else {
        print("Mint does not advertise NUT-15 support")
    }
}
