//
//  CashuWallet+Transactions.swift
//  CoreCashu
//
//  Core transaction operations: mint, melt, send, receive
//

import Foundation

// MARK: - Core Wallet Operations

public extension CashuWallet {
    
    /// Mint new tokens from a payment request
    /// - Parameters:
    ///   - amount: Amount to mint
    ///   - paymentRequest: Payment request (e.g., Lightning invoice)
    ///   - method: Payment method (defaults to "bolt11")
    /// - Returns: Mint result with new proofs
    func mint(
        amount: Int,
        paymentRequest: String,
        method: String = "bolt11"
    ) async throws -> MintResult {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        
        guard amount > 0 else {
            throw CashuError.invalidAmount
        }
        
        guard let mintService = mintService else {
            throw CashuError.walletNotInitialized
        }
        
        let timer = metrics.startTimer()
        await metrics.increment(CashuMetrics.mintStart, tags: ["mint": configuration.mintURL, "unit": configuration.unit])
        
        let result = try await mintService.mint(
            amount: amount,
            method: method,
            unit: configuration.unit,
            at: configuration.mintURL
        )
        
        await metrics.increment(CashuMetrics.mintSuccess, tags: ["mint": configuration.mintURL, "unit": configuration.unit])
        await metrics.gauge(CashuMetrics.mintAmount, value: Double(amount), tags: ["mint": configuration.mintURL, "unit": configuration.unit])
        await timer.stop(metricName: CashuMetrics.mintDuration, tags: ["mint": configuration.mintURL, "unit": configuration.unit])
        
        return result
    }
    
    /// Send tokens (prepare for transfer)
    /// - Parameters:
    ///   - amount: Amount to send
    ///   - memo: Optional memo
    /// - Returns: Cashu token ready for transfer
    func send(amount: Int, memo: String? = nil) async throws -> CashuToken {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        
        guard amount > 0 else {
            throw CashuError.invalidAmount
        }
        
        // Select proofs for the amount
        let selectedProofs = try await proofManager.selectProofs(amount: amount)
        
        let tokenEntry = TokenEntry(
            mint: configuration.mintURL,
            proofs: selectedProofs
        )
        
        return CashuToken(
            token: [tokenEntry],
            unit: configuration.unit,
            memo: memo
        )
    }
    
    /// Select proofs for a specific amount
    /// - Parameter amount: Amount to select proofs for
    /// - Returns: Array of selected proofs
    func selectProofsForAmount(_ amount: Int) async throws -> [Proof] {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        
        guard amount > 0 else {
            throw CashuError.invalidAmount
        }
        
        return try await proofManager.selectProofs(amount: amount)
    }
    
    /// Receive tokens from another wallet
    /// - Parameter token: Cashu token to receive
    /// - Returns: Array of new proofs
    func receive(token: CashuToken) async throws -> [Proof] {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        
        var allNewProofs: [Proof] = []
        
        // Process each token entry
        for tokenEntry in token.token {
            // Validate token entry is for our mint
            guard tokenEntry.mint == configuration.mintURL else {
                throw CashuError.invalidMintConfiguration
            }
            
            // Add proofs to our storage
            try await proofManager.addProofs(tokenEntry.proofs)
            allNewProofs.append(contentsOf: tokenEntry.proofs)
        }
        
        return allNewProofs
    }
    
    /// Melt tokens (spend via Lightning)
    /// - Parameters:
    ///   - paymentRequest: Lightning payment request
    ///   - method: Payment method (defaults to "bolt11")
    /// - Returns: Melt result
    func melt(
        paymentRequest: String,
        method: String = "bolt11"
    ) async throws -> MeltResult {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        
        guard let meltService = meltService else {
            throw CashuError.walletNotInitialized
        }
        
        // Prepare melt to know exactly which proofs will be used
        let availableProofs = try await proofManager.getAvailableProofs()
        
        let preparation = try await meltService.prepareMelt(
            paymentRequest: paymentRequest,
            method: PaymentMethod(rawValue: method) ?? .bolt11,
            unit: configuration.unit,
            availableProofs: availableProofs,
            at: configuration.mintURL
        )
        
        // Mark selected proofs as pending spent
        try await proofManager.markAsPendingSpent(preparation.inputProofs)
        
        let timer = metrics.startTimer()
        await metrics.increment(CashuMetrics.meltStart, tags: ["mint": configuration.mintURL, "unit": configuration.unit])
        
        do {
            let result = try await meltService.executeCompleteMelt(
                preparation: preparation,
                method: PaymentMethod(rawValue: method) ?? .bolt11,
                at: configuration.mintURL
            )
            
            if result.state == .paid {
                try await proofManager.finalizePendingSpent(preparation.inputProofs)
                try await proofManager.markAsSpent(preparation.inputProofs)
                try await proofManager.removeProofs(preparation.inputProofs)
                if !result.changeProofs.isEmpty {
                    try await proofManager.addProofs(result.changeProofs)
                }
                await metrics.increment(CashuMetrics.meltFinalized, tags: ["mint": configuration.mintURL])
                await timer.stop(metricName: CashuMetrics.meltDuration, tags: ["mint": configuration.mintURL])
            } else {
                try await proofManager.rollbackPendingSpent(preparation.inputProofs)
                await metrics.increment(CashuMetrics.meltRolledBack, tags: ["mint": configuration.mintURL, "state": String(describing: result.state)])
            }
            
            return result
        } catch {
            try await proofManager.rollbackPendingSpent(preparation.inputProofs)
            await metrics.increment(CashuMetrics.meltFailure, tags: ["mint": configuration.mintURL, "error": String(describing: error)])
            throw error
        }
    }
}

// WalletStatistics is defined in CashuWallet.swift
