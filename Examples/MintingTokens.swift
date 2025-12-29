/// # Minting Tokens
///
/// This example demonstrates how to mint new Cashu tokens from Lightning payments.

import CoreCashu
import Foundation

// MARK: - Basic Minting Flow

/// Complete minting flow: request quote -> pay invoice -> mint tokens
func mintTokens(wallet: CashuWallet, amount: Int) async throws {
    // Step 1: Request a mint quote
    let quote = try await wallet.requestMintQuote(amount: amount, method: .bolt11)
    
    print("Pay this Lightning invoice: \(quote.request)")
    print("Quote ID: \(quote.quote)")
    print("Quote expires at: \(quote.expiry ?? 0)")
    
    // Step 2: Wait for payment (in a real app, poll or use callbacks)
    var isPaid = false
    while !isPaid {
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
        
        let status = try await wallet.checkMintQuoteStatus(quoteId: quote.quote)
        isPaid = status.state == .paid
        
        print("Payment status: \(status.state)")
    }
    
    // Step 3: Mint the tokens
    let mintResult = try await wallet.mint(
        amount: amount,
        quoteId: quote.quote,
        method: .bolt11
    )
    
    print("Minted \(mintResult.newProofs.count) proofs")
    print("Total minted: \(mintResult.newProofs.reduce(0) { $0 + $1.amount }) sats")
}

// MARK: - Minting with Progress Callback

/// Mint tokens with progress updates
func mintWithProgress(wallet: CashuWallet, amount: Int) async throws {
    let quote = try await wallet.requestMintQuote(amount: amount, method: .bolt11)
    
    print("Invoice: \(quote.request)")
    
    // Poll for payment with timeout
    let timeout: TimeInterval = 300 // 5 minutes
    let startTime = Date()
    
    while Date().timeIntervalSince(startTime) < timeout {
        let status = try await wallet.checkMintQuoteStatus(quoteId: quote.quote)
        
        switch status.state {
        case .paid:
            print("Payment confirmed! Minting tokens...")
            let result = try await wallet.mint(
                amount: amount,
                quoteId: quote.quote,
                method: .bolt11
            )
            print("Success! Minted \(result.newProofs.count) proofs")
            return
            
        case .unpaid:
            print("Waiting for payment... (\(Int(Date().timeIntervalSince(startTime)))s)")
            try await Task.sleep(nanoseconds: 3_000_000_000)
            
        case .pending:
            print("Payment pending...")
            try await Task.sleep(nanoseconds: 1_000_000_000)
            
        case .issued:
            print("Tokens already issued for this quote")
            return
        }
    }
    
    print("Timeout waiting for payment")
}

// MARK: - Checking Mint Quote Status

/// Check the status of an existing mint quote
func checkQuoteStatus(wallet: CashuWallet, quoteId: String) async throws {
    let status = try await wallet.checkMintQuoteStatus(quoteId: quoteId)
    
    print("Quote ID: \(quoteId)")
    print("State: \(status.state)")
    
    switch status.state {
    case .unpaid:
        print("Invoice has not been paid yet")
    case .pending:
        print("Payment is being processed")
    case .paid:
        print("Payment confirmed - ready to mint")
    case .issued:
        print("Tokens have already been issued")
    }
}

// MARK: - Error Handling

/// Mint with comprehensive error handling
func safeMint(wallet: CashuWallet, amount: Int) async throws {
    do {
        // Request quote
        let quote = try await wallet.requestMintQuote(amount: amount, method: .bolt11)
        print("Quote created: \(quote.quote)")
        
        // In production, handle the invoice payment externally
        // Then mint:
        let result = try await wallet.mint(
            amount: amount,
            quoteId: quote.quote,
            method: .bolt11
        )
        
        print("Successfully minted \(result.newProofs.count) proofs")
        
    } catch let error as CashuError {
        switch error {
        case .quoteNotPaid:
            print("Error: Invoice has not been paid yet")
        case .quoteExpired:
            print("Error: Quote has expired, request a new one")
        case .networkError(let underlying):
            print("Network error: \(underlying.localizedDescription)")
            // May be retryable
        case .mintError(let code, let message):
            print("Mint error \(code): \(message)")
        default:
            print("Error: \(error.localizedDescription)")
        }
    }
}

// MARK: - Denomination Selection

/// Mint with specific denominations (advanced usage)
func mintWithDenominations(wallet: CashuWallet, amount: Int) async throws {
    // Get available denominations from mint
    let info = try await wallet.getMintInfo()
    
    print("Mint: \(info.name ?? "Unknown")")
    print("Supported units: \(info.nuts?["1"]?.description ?? "unknown")")
    
    // Standard mint flow uses optimal denomination selection
    let quote = try await wallet.requestMintQuote(amount: amount, method: .bolt11)
    
    // The wallet automatically selects optimal denominations
    // For 1000 sats, it might create: 512 + 256 + 128 + 64 + 32 + 8 = 1000
    
    // After payment:
    // let result = try await wallet.mint(amount: amount, quoteId: quote.quote, method: .bolt11)
    
    print("Requested quote for \(amount) sats")
    print("Invoice: \(quote.request)")
}
