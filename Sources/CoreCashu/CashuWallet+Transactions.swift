//
//  CashuWallet+Transactions.swift
//  CoreCashu
//
//  Core transaction operations: mint, melt, send, receive
//

import Foundation

// MARK: - Core Wallet Operations

public extension CashuWallet {

    /// Request a mint quote.
    /// - Parameters:
    ///   - amount: Amount to mint
    ///   - method: Payment method (defaults to "bolt11")
    /// - Returns: Mint quote response containing the payment request
    func requestMintQuote(amount: Int, method: String = "bolt11") async throws -> MintQuoteResponse {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        guard amount > 0 else {
            throw CashuError.invalidAmount
        }
        guard let mintService = mintService else {
            throw CashuError.walletNotInitialized
        }

        return try await mintService.getMintQuote(
            amount: amount,
            method: method,
            unit: configuration.unit,
            at: configuration.mintURL
        )
    }

    /// Check mint quote state.
    /// - Parameters:
    ///   - quoteID: Quote identifier
    ///   - method: Payment method (defaults to "bolt11")
    /// - Returns: Current quote state
    func checkMintQuote(_ quoteID: String, method: String = "bolt11") async throws -> MintQuoteResponse {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        guard let mintService = mintService else {
            throw CashuError.walletNotInitialized
        }

        return try await mintService.checkMintQuote(quoteID, method: method, at: configuration.mintURL)
    }

    /// Mint using an existing quote.
    /// - Parameters:
    ///   - quoteID: Quote identifier
    ///   - amount: Amount to mint
    ///   - method: Payment method (defaults to "bolt11")
    /// - Returns: Mint result with newly created proofs
    func mint(
        quoteID: String,
        amount: Int,
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

        let currentQuote = try await mintService.checkMintQuote(quoteID, method: method, at: configuration.mintURL)
        if currentQuote.isExpired {
            throw CashuError.quoteExpired
        }
        if currentQuote.isIssued {
            throw CashuError.invalidState("Mint quote is already issued")
        }
        guard currentQuote.canMint else {
            throw CashuError.quotePending
        }

        let timer = metrics.startTimer()
        await metrics.increment(CashuMetrics.mintStart, tags: ["mint": configuration.mintURL, "unit": configuration.unit])

        let preparation = try await mintService.prepareMint(
            quote: quoteID,
            amount: amount,
            method: method,
            unit: configuration.unit,
            at: configuration.mintURL
        )
        let result = try await mintService.executeCompleteMint(
            preparation: preparation,
            method: method,
            at: configuration.mintURL
        )

        try await proofManager.addProofs(result.newProofs)

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
        
        guard let swapService = swapService else {
            throw CashuError.walletNotInitialized
        }

        let availableProofs = try await proofManager.getAvailableProofs()
        let preparation = try await swapService.prepareSwapToSend(
            availableProofs: availableProofs,
            targetAmount: amount,
            unit: configuration.unit,
            at: configuration.mintURL
        )

        try await proofManager.markAsPendingSpent(preparation.inputProofs)
        do {
            let swapResult = try await swapService.executeCompleteSwap(
                preparation: preparation,
                at: configuration.mintURL
            )

            let (sendProofs, changeProofs) = try partitionSwapOutputs(
                swapResult.newProofs,
                targetAmount: amount,
                targetDenominations: preparation.targetOutputDenominations
            )

            try await proofManager.finalizePendingSpent(preparation.inputProofs)
            try await proofManager.markAsSpent(preparation.inputProofs)
            try await proofManager.removeProofs(preparation.inputProofs)

            if !changeProofs.isEmpty {
                try await proofManager.addProofs(changeProofs)
            }

            let tokenEntry = TokenEntry(mint: configuration.mintURL, proofs: sendProofs)
            return CashuToken(
                token: [tokenEntry],
                unit: configuration.unit,
                memo: memo
            )
        } catch {
            try await proofManager.rollbackPendingSpent(preparation.inputProofs)
            throw error
        }
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
        guard let swapService = swapService else {
            throw CashuError.walletNotInitialized
        }
        
        var allNewProofs: [Proof] = []
        
        // Process each token entry
        for tokenEntry in token.token {
            // Validate token entry is for our mint
            guard tokenEntry.mint == configuration.mintURL else {
                throw CashuError.invalidMintConfiguration
            }
            
            // Always swap received proofs to invalidate sender's proofs and get fresh outputs.
            let swapResult = try await swapService.swapToReceive(
                proofs: tokenEntry.proofs,
                at: configuration.mintURL
            )
            try await proofManager.addProofs(swapResult.newProofs)
            allNewProofs.append(contentsOf: swapResult.newProofs)
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

extension CashuWallet {
    private func partitionSwapOutputs(
        _ newProofs: [Proof],
        targetAmount: Int,
        targetDenominations: [Int]
    ) throws -> (sendProofs: [Proof], changeProofs: [Proof]) {
        guard !newProofs.isEmpty else {
            throw CashuError.invalidState("Swap returned no proofs")
        }

        if !targetDenominations.isEmpty {
            var requiredByAmount: [Int: Int] = [:]
            for amount in targetDenominations {
                requiredByAmount[amount, default: 0] += 1
            }

            var send: [Proof] = []
            var change: [Proof] = []
            for proof in newProofs.sorted(by: { $0.amount < $1.amount }) {
                let needed = requiredByAmount[proof.amount] ?? 0
                if needed > 0 {
                    send.append(proof)
                    requiredByAmount[proof.amount] = needed - 1
                } else {
                    change.append(proof)
                }
            }

            if requiredByAmount.values.allSatisfy({ $0 == 0 }) {
                let sendTotal = send.reduce(0) { $0 + $1.amount }
                guard sendTotal == targetAmount else {
                    throw CashuError.invalidState("Swap output partition mismatch")
                }
                return (send, change)
            }
        }

        throw CashuError.invalidState("Could not partition swap outputs for exact send amount")
    }
}
