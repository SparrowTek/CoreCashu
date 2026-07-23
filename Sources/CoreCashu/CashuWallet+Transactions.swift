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
        // Minting less than the quote was paid for forfeits the difference once the quote
        // flips to ISSUED — refuse a mismatched amount outright.
        if let quoteAmount = currentQuote.amount, quoteAmount != amount {
            throw CashuError.invalidAmount
        }

        let timer = metrics.startTimer()
        await metrics.increment(CashuMetrics.mintStart, tags: ["mint": configuration.mintURL, "unit": configuration.unit])

        let preparation = try await mintService.prepareMint(
            quote: quoteID,
            amount: amount,
            method: method,
            unit: configuration.unit,
            at: configuration.mintURL,
            deterministicOutputs: deterministicOutputProvider()
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
            at: configuration.mintURL,
            deterministicOutputs: deterministicOutputProvider()
        )

        try await proofManager.markAsPendingSpent(preparation.inputProofs)

        let swapResult: SwapResult
        do {
            swapResult = try await swapService.executeCompleteSwap(
                preparation: preparation,
                at: configuration.mintURL
            )
        } catch {
            // The swap did not complete on our side. Release the reservation only when the
            // mint verifiably did not consume the inputs — otherwise the "failed" swap may
            // have gone through (lost response) and re-spending the inputs would fork
            // local state from the mint's.
            if Self.isDefiniteRejection(error) {
                try await proofManager.rollbackPendingSpent(preparation.inputProofs)
                throw error
            }
            if let unspent = try? await allInputsUnspent(preparation.inputProofs), unspent {
                try await proofManager.rollbackPendingSpent(preparation.inputProofs)
                throw error
            }
            // Inputs are spent or unverifiable: keep them reserved. With deterministic
            // outputs the swapped value is recoverable via restoreFromSeed.
            throw CashuError.wrappedFailure(
                message: "Swap outcome unknown; inputs stay reserved. Run restoreFromSeed to recover outputs if the swap settled.",
                underlying: error
            )
        }

        // From here the mint has spent the inputs — they must never return to spendable.
        let sendProofs: [Proof]
        let changeProofs: [Proof]
        do {
            (sendProofs, changeProofs) = try partitionSwapOutputs(
                swapResult.newProofs,
                targetAmount: amount,
                targetDenominations: preparation.targetOutputDenominations,
                targetSecrets: preparation.targetSecrets
            )
        } catch {
            // The swap settled but the outputs couldn't be split into send/change (e.g.
            // the mint returned unexpected denominations). Keep every new proof — the
            // value belongs to this wallet — retire the inputs, and report the failure;
            // no token is handed out.
            try await proofManager.addProofs(swapResult.newProofs)
            try await proofManager.finalizePendingSpent(preparation.inputProofs)
            try await proofManager.markAsSpent(preparation.inputProofs)
            try await proofManager.removeProofs(preparation.inputProofs)
            throw error
        }

        // Persist the mint-signed change before touching the inputs so a failure between
        // the two duplicates locally (recoverable) instead of losing proofs. A storage
        // failure past this point deliberately leaves the inputs reserved, never rolled back.
        if !changeProofs.isEmpty {
            try await proofManager.addProofs(changeProofs)
        }
        try await proofManager.finalizePendingSpent(preparation.inputProofs)
        try await proofManager.markAsSpent(preparation.inputProofs)
        try await proofManager.removeProofs(preparation.inputProofs)

        let tokenEntry = TokenEntry(mint: configuration.mintURL, proofs: sendProofs)
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
        guard let swapService = swapService else {
            throw CashuError.walletNotInitialized
        }
        
        // Validate every entry BEFORE swapping any: failing on entry N after entries
        // 1..N−1 were already claimed leaves the token half-redeemed with no signal to
        // the caller about which parts went through.
        for tokenEntry in token.token {
            guard tokenEntry.mint == configuration.mintURL else {
                throw CashuError.invalidMintConfiguration
            }
        }

        var allNewProofs: [Proof] = []

        // Process each token entry
        for tokenEntry in token.token {
            // Always swap received proofs to invalidate sender's proofs and get fresh outputs.
            let swapResult = try await swapService.swapToReceive(
                proofs: tokenEntry.proofs,
                at: configuration.mintURL,
                deterministicOutputs: deterministicOutputProvider()
            )
            try await proofManager.addProofs(swapResult.newProofs)
            allNewProofs.append(contentsOf: swapResult.newProofs)
        }

        return allNewProofs
    }
    
    /// Melt tokens (spend via Lightning)
    ///
    /// On a PENDING payment or an ambiguous transport failure the selected proofs stay
    /// reserved (never returned to the spendable balance) and the quote is tracked; call
    /// ``resolvePendingMelt(quoteID:method:)`` to settle it once the payment resolves.
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

        let paymentMethod = PaymentMethod(rawValue: method) ?? .bolt11

        // Prepare melt to know exactly which proofs will be used
        let availableProofs = try await proofManager.getAvailableProofs()

        let preparation = try await meltService.prepareMelt(
            paymentRequest: paymentRequest,
            method: paymentMethod,
            unit: configuration.unit,
            availableProofs: availableProofs,
            at: configuration.mintURL,
            deterministicOutputs: deterministicOutputProvider()
        )

        // Mark selected proofs as pending spent
        try await proofManager.markAsPendingSpent(preparation.inputProofs)

        let timer = metrics.startTimer()
        await metrics.increment(CashuMetrics.meltStart, tags: ["mint": configuration.mintURL, "unit": configuration.unit])

        let result: MeltResult
        do {
            result = try await meltService.executeCompleteMelt(
                preparation: preparation,
                method: paymentMethod,
                at: configuration.mintURL
            )
        } catch {
            if Self.isDefiniteRejection(error) {
                // The mint verifiably rejected (or never received) the request — the
                // inputs are untouched and safe to release.
                try await proofManager.rollbackPendingSpent(preparation.inputProofs)
                await metrics.increment(CashuMetrics.meltFailure, tags: ["mint": configuration.mintURL, "error": String(describing: error)])
                throw error
            }
            // Ambiguous outcome (timeout, lost response, failure after the mint may have
            // started paying): keep the inputs reserved and track the quote for later
            // resolution — releasing them here is how wallets double-spend against
            // themselves and corrupt local state.
            pendingMeltPreparations[preparation.quote.quote] = preparation
            await metrics.increment(CashuMetrics.meltFailure, tags: ["mint": configuration.mintURL, "error": String(describing: error), "outcome": "unknown"])
            throw CashuError.meltOutcomeUnknown(quoteID: preparation.quote.quote)
        }

        switch result.state {
        case .paid:
            try await finalizeSuccessfulMelt(preparation: preparation, changeProofs: result.changeProofs)
            await metrics.increment(CashuMetrics.meltFinalized, tags: ["mint": configuration.mintURL])
            await timer.stop(metricName: CashuMetrics.meltDuration, tags: ["mint": configuration.mintURL])
        case .pending:
            // Lightning payment in flight: the inputs are committed at the mint until the
            // payment settles or fails. Track the quote; resolvePendingMelt settles it.
            pendingMeltPreparations[preparation.quote.quote] = preparation
            await metrics.increment(CashuMetrics.meltFailure, tags: ["mint": configuration.mintURL, "outcome": "pending"])
        case .unpaid:
            try await proofManager.rollbackPendingSpent(preparation.inputProofs)
            await metrics.increment(CashuMetrics.meltRolledBack, tags: ["mint": configuration.mintURL, "state": String(describing: result.state)])
        }

        return result
    }

    /// Melt quotes whose inputs are reserved awaiting resolution.
    var pendingMeltQuoteIDs: [String] {
        Array(pendingMeltPreparations.keys)
    }

    /// Check the current state of a melt quote at the mint.
    func checkMeltQuote(_ quoteID: String, method: String = "bolt11") async throws -> PostMeltQuoteResponse {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        guard let meltService = meltService else {
            throw CashuError.walletNotInitialized
        }
        return try await meltService.checkMeltQuote(
            quoteID: quoteID,
            method: PaymentMethod(rawValue: method) ?? .bolt11,
            at: configuration.mintURL
        )
    }

    /// Settle a melt tracked by ``melt(paymentRequest:method:)`` after a PENDING payment
    /// or an ambiguous failure: re-checks the quote and finalizes (PAID), keeps waiting
    /// (PENDING), or releases the reserved inputs (UNPAID).
    /// - Returns: The quote state after resolution.
    @discardableResult
    func resolvePendingMelt(quoteID: String, method: String = "bolt11") async throws -> MeltQuoteState {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        guard let meltService = meltService else {
            throw CashuError.walletNotInitialized
        }
        guard let preparation = pendingMeltPreparations[quoteID] else {
            throw CashuError.quoteNotFound
        }

        let quote = try await meltService.checkMeltQuote(
            quoteID: quoteID,
            method: PaymentMethod(rawValue: method) ?? .bolt11,
            at: configuration.mintURL
        )

        switch quote.state {
        case .paid:
            // Recover NUT-08 change from the quote when the mint provides it (the melt
            // response that carried it originally was lost).
            var changeProofs: [Proof] = []
            if let changeSignatures = quote.change,
               !changeSignatures.isEmpty,
               let blindingData = preparation.blindingData {
                changeProofs = try await meltService.unblindMeltChange(
                    changeSignatures,
                    blindingData: blindingData,
                    at: configuration.mintURL
                )
            }
            try await finalizeSuccessfulMelt(preparation: preparation, changeProofs: changeProofs)
            await metrics.increment(CashuMetrics.meltFinalized, tags: ["mint": configuration.mintURL, "resolved": "true"])
        case .pending:
            break
        case .unpaid:
            try await proofManager.rollbackPendingSpent(preparation.inputProofs)
            pendingMeltPreparations.removeValue(forKey: quoteID)
            await metrics.increment(CashuMetrics.meltRolledBack, tags: ["mint": configuration.mintURL, "resolved": "true"])
        }

        return quote.state
    }
}

// MARK: - Melt helpers

extension CashuWallet {

    /// Persist a successful melt: change first, then retire the inputs. The inputs are
    /// spent at the mint by the time this runs, so a persistence failure keeps them
    /// reserved (tracked in `pendingMeltPreparations`) rather than rolling them back.
    internal func finalizeSuccessfulMelt(preparation: MeltPreparation, changeProofs: [Proof]) async throws {
        do {
            if !changeProofs.isEmpty {
                // Tolerate re-runs: skip change already persisted by an earlier attempt.
                let known = Set(try await proofManager.getAllProofs().map { $0.secret })
                let fresh = changeProofs.filter { !known.contains($0.secret) }
                if !fresh.isEmpty {
                    try await proofManager.addProofs(fresh)
                }
            }
            try await proofManager.finalizePendingSpent(preparation.inputProofs)
            try await proofManager.markAsSpent(preparation.inputProofs)
            try await proofManager.removeProofs(preparation.inputProofs)
        } catch {
            pendingMeltPreparations[preparation.quote.quote] = preparation
            throw error
        }
        pendingMeltPreparations.removeValue(forKey: preparation.quote.quote)
    }

    /// Whether every input proof is verifiably UNSPENT at the mint.
    internal func allInputsUnspent(_ proofs: [Proof]) async throws -> Bool {
        let stateResult = try await checkProofStates(proofs)
        return stateResult.results.allSatisfy { $0.stateInfo.state == .unspent }
    }

    /// True when `error` proves the mint rejected (or never received) the request, so the
    /// operation's inputs were not consumed. Transport timeouts, 5xx responses, and
    /// post-response failures are NOT definite — the request may have been processed.
    internal static func isDefiniteRejection(_ error: any Error) -> Bool {
        guard let networkError = error as? NetworkError else {
            // Anything else (URLError, decode failures after a 2xx, …) is ambiguous.
            return false
        }

        switch networkError {
        case .statusCode(let code?, let data):
            let raw = code.rawValue
            guard (400..<500).contains(raw), raw != 408, raw != 429 else {
                // 5xx / timeout-ish statuses don't prove the request wasn't processed.
                return false
            }
            // Prefer the NUT-00 protocol code in the body over the HTTP status: some 400s
            // mean "your inputs are already committed" and must NOT release them.
            if let cashuError = try? JSONDecoder().decode(CashuHTTPError.self, from: data) {
                switch cashuError.code {
                case 10002, // blinded message already signed (a prior attempt landed)
                     11001, // token already spent
                     20005, // quote is pending (payment in flight)
                     20006: // invoice already paid
                    return false
                default:
                    return true
                }
            }
            return true
        case .encodingFailed, .missingURL, .circuitOpen:
            return true // request never left the wallet
        default:
            return false
        }
    }
}

// WalletStatistics is defined in CashuWallet.swift

extension CashuWallet {
    private func partitionSwapOutputs(
        _ newProofs: [Proof],
        targetAmount: Int,
        targetDenominations: [Int],
        targetSecrets: Set<String> = []
    ) throws -> (sendProofs: [Proof], changeProofs: [Proof]) {
        guard !newProofs.isEmpty else {
            throw CashuError.invalidState("Swap returned no proofs")
        }

        // When the wallet locked the target outputs, identification by `secret` is exact:
        // each target proof carries the locked NUT-10 well-known secret and change proofs do
        // not. Denomination-based matching breaks down when target and change share a
        // denomination, so prefer secret-based partitioning whenever available.
        if !targetSecrets.isEmpty {
            var send: [Proof] = []
            var change: [Proof] = []
            for proof in newProofs {
                if targetSecrets.contains(proof.secret) {
                    send.append(proof)
                } else {
                    change.append(proof)
                }
            }
            let sendTotal = send.reduce(0) { $0 + $1.amount }
            guard sendTotal == targetAmount else {
                throw CashuError.invalidState("Swap output partition mismatch (locked path)")
            }
            return (send, change)
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
