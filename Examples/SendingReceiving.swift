/// # Sending and Receiving Tokens
///
/// This example demonstrates how to send and receive Cashu tokens between wallets.

import CoreCashu
import Foundation

// MARK: - Sending Tokens

/// Send tokens to another user
func sendTokens(wallet: CashuWallet, amount: Int, memo: String? = nil) async throws -> String {
    // Check balance first
    let balance = try await wallet.balance
    guard balance >= amount else {
        throw CashuError.insufficientBalance(required: amount, available: balance)
    }
    
    // Create the token
    let token = try await wallet.send(amount: amount, memo: memo)
    
    // Serialize to a shareable string
    let tokenString = try token.serialize()
    
    print("Created token for \(amount) sats")
    print("Token: \(tokenString)")
    
    return tokenString
}

/// Send exact proofs (no change)
func sendExactAmount(wallet: CashuWallet, amount: Int) async throws -> String {
    // The wallet automatically selects proofs to cover the amount
    // If exact amount isn't available, it will create change
    
    let token = try await wallet.send(amount: amount)
    return try token.serialize()
}

// MARK: - Receiving Tokens

/// Receive a token from another user
func receiveToken(wallet: CashuWallet, tokenString: String) async throws {
    // Parse and validate the token
    let proofs = try await wallet.receive(token: tokenString)
    
    let totalReceived = proofs.reduce(0) { $0 + $1.amount }
    print("Received \(proofs.count) proofs")
    print("Total: \(totalReceived) sats")
    
    // Check new balance
    let newBalance = try await wallet.balance
    print("New wallet balance: \(newBalance) sats")
}

/// Receive with verification
func receiveWithVerification(wallet: CashuWallet, tokenString: String) async throws {
    do {
        // The receive operation:
        // 1. Deserializes and validates the token
        // 2. Checks if tokens are already spent
        // 3. Swaps for fresh proofs from the mint
        // 4. Stores the new proofs
        
        let proofs = try await wallet.receive(token: tokenString)
        print("Successfully received \(proofs.count) proofs")
        
    } catch let error as CashuError {
        switch error {
        case .tokenAlreadySpent:
            print("Error: This token has already been spent")
        case .invalidToken(let reason):
            print("Error: Invalid token - \(reason)")
        case .mintMismatch:
            print("Error: Token is from a different mint")
        default:
            print("Error receiving token: \(error.localizedDescription)")
        }
    }
}

// MARK: - Token Inspection

/// Inspect a token without receiving it
func inspectToken(tokenString: String) throws {
    // Parse the token
    let token = try CashuToken.deserialize(tokenString)
    
    print("Token version: \(token.version)")
    print("Mint: \(token.mint)")
    print("Unit: \(token.unit ?? "sat")")
    print("Memo: \(token.memo ?? "none")")
    
    // Sum up the value
    let totalValue = token.proofs.reduce(0) { $0 + $1.amount }
    print("Total value: \(totalValue) sats")
    print("Number of proofs: \(token.proofs.count)")
    
    // List denominations
    let denominations = token.proofs.map { $0.amount }.sorted()
    print("Denominations: \(denominations)")
}

// MARK: - Token State Checking

/// Check if a token is still valid (not spent)
func checkTokenState(wallet: CashuWallet, tokenString: String) async throws {
    let token = try CashuToken.deserialize(tokenString)
    
    // Check proof states with the mint
    let batch = try await wallet.checkProofStates(token.proofs)
    
    for result in batch.results {
        let proofY = try result.proof.calculateY()
        print("Proof \(proofY.prefix(8))...: \(result.stateInfo.state)")
    }
    
    // Summary
    let spentCount = batch.results.filter { $0.stateInfo.state == .spent }.count
    let unspentCount = batch.results.filter { $0.stateInfo.state == .unspent }.count
    let pendingCount = batch.results.filter { $0.stateInfo.state == .pending }.count
    
    print("\nSummary:")
    print("  Unspent: \(unspentCount)")
    print("  Spent: \(spentCount)")
    print("  Pending: \(pendingCount)")
}

// MARK: - Token Formats

/// Work with different token formats
func tokenFormats() throws {
    // V3 token (JSON-based, legacy)
    let v3TokenString = "cashuAeyJ0b2tlbiI6..."
    
    // V4 token (CBOR-based, more compact)
    let v4TokenString = "cashuBo2F0gaJ..."
    
    // The deserialize method auto-detects the format
    // let token = try CashuToken.deserialize(v4TokenString)
    
    // Create a V4 token (default for new tokens)
    // let newToken = try wallet.send(amount: 100)
    // let serialized = try newToken.serialize() // Uses V4 by default
}

// MARK: - Batch Operations

/// Send multiple tokens in parallel
func sendMultipleTokens(
    wallet: CashuWallet,
    amounts: [Int]
) async throws -> [String] {
    // Verify total balance
    let totalNeeded = amounts.reduce(0, +)
    let balance = try await wallet.balance
    
    guard balance >= totalNeeded else {
        throw CashuError.insufficientBalance(required: totalNeeded, available: balance)
    }
    
    // Send sequentially (to avoid proof conflicts)
    var tokens: [String] = []
    for amount in amounts {
        let token = try await wallet.send(amount: amount)
        tokens.append(try token.serialize())
    }
    
    return tokens
}

/// Receive multiple tokens
func receiveMultipleTokens(
    wallet: CashuWallet,
    tokenStrings: [String]
) async throws -> Int {
    var totalReceived = 0
    
    for tokenString in tokenStrings {
        do {
            let proofs = try await wallet.receive(token: tokenString)
            let amount = proofs.reduce(0) { $0 + $1.amount }
            totalReceived += amount
            print("Received \(amount) sats")
        } catch {
            print("Failed to receive token: \(error.localizedDescription)")
            // Continue with other tokens
        }
    }
    
    return totalReceived
}
