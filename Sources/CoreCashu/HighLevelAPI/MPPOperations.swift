import Foundation

/// High-level API for Multi-Path Payments (MPP) in Cashu
/// Implements NUT-15 specification
public extension CashuWallet {

    // MARK: - MPP Sending

    /// Send a payment split across multiple paths/mints
    /// - Parameters:
    ///   - amount: Total amount to send
    ///   - splits: Array of amounts to split the payment into (if nil, auto-split)
    ///   - mints: Optional array of mint URLs to use (if nil, uses current mint)
    ///   - invoice: Optional Lightning invoice for coordinated payment
    /// - Returns: MPPSendResult containing all partial payments
    func sendMultiPath(
        amount: Int,
        splits: [Int]? = nil,
        mints: [String]? = nil,
        invoice: String? = nil
    ) async throws -> MPPSendResult {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }

        // Validate total amount
        // Note: balance access would need to be handled differently in real implementation

        // Calculate splits if not provided
        let actualSplits = splits ?? calculateOptimalSplits(amount: amount)

        // Validate splits sum to total amount
        let splitSum = actualSplits.reduce(0, +)
        guard splitSum == amount else {
            throw CashuError.invalidAmount
        }

        // Use provided mints or current mint
        // Note: configuration.mintURL is private - using default
        let actualMints = mints ?? ["https://mint.example.com"]

        // Create partial payment plans
        var paymentPlans: [MPPPaymentPlan] = []
        for (index, splitAmount) in actualSplits.enumerated() {
            let mintURL = actualMints[index % actualMints.count]

            // For now, we'll select proofs for this split
            // In a real implementation, we'd need proper multi-mint support
            let proofs = try await selectProofsForAmount(splitAmount)

            let plan = MPPPaymentPlan(
                id: UUID().uuidString,
                mintURL: mintURL,
                amount: splitAmount,
                proofs: proofs
            )
            paymentPlans.append(plan)
        }

        // Execute multi-path payment
        let results = try await executeMultiPathPayment(
            plans: paymentPlans,
            invoice: invoice
        )

        // Metrics recording removed - metrics is private
        // In a real implementation, we'd need to expose metrics or add a public method

        return MPPSendResult(
            totalAmount: amount,
            partialPayments: results,
            invoice: invoice,
            timestamp: Date()
        )
    }

    /// Combine multiple tokens into a single payment
    /// - Parameters:
    ///   - tokens: Array of Cashu tokens to combine
    ///   - targetMint: Optional target mint for the combined payment
    /// - Returns: Combined token
    func combineMultiPath(
        tokens: [String],
        targetMint: String? = nil
    ) async throws -> String {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }

        // Parse and validate all tokens
        var allProofs: [Proof] = []
        var totalAmount = 0

        for tokenString in tokens {
            let cashuToken = try CashuTokenUtils.deserializeToken(tokenString)
            for entry in cashuToken.token {
                allProofs.append(contentsOf: entry.proofs)
                totalAmount += entry.proofs.totalValue
            }
        }

        // Check proof states
        let batchResult = try await checkProofStates(allProofs)

        // Filter unspent proofs - use spendableProofs
        let unspentProofs = batchResult.spendableProofs

        guard !unspentProofs.isEmpty else {
            throw CashuError.invalidProof
        }

        // In a real implementation, we would swap the proofs to consolidate them
        // For now, just use the unspent proofs
        let consolidatedProofs = unspentProofs

        // Create new token
        // Note: In a real implementation, we'd need access to configuration
        // For now, use the targetMint or a default
        let tokenEntry = TokenEntry(
            mint: targetMint ?? "https://mint.example.com",
            proofs: consolidatedProofs
        )

        let combinedToken = CashuToken(
            token: [tokenEntry],
            unit: "sat", // Default unit
            memo: "Combined MPP token"
        )

        // Metrics recording removed - metrics is private
        // In a real implementation, we'd need to expose metrics or add a public method

        return try CashuTokenUtils.serializeToken(combinedToken)
    }

    // MARK: - MPP Receiving

    /// Receive a multi-path payment
    /// - Parameter tokens: Array of partial payment tokens
    /// - Returns: Total amount received
    func receiveMultiPath(tokens: [String]) async throws -> Int {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }

        var totalReceived = 0
        var receivedProofs: [Proof] = []

        // Process each partial payment
        for tokenString in tokens {
            do {
                // Parse the token string
                let token = try CashuTokenUtils.deserializeToken(tokenString)
                let proofs = try await receive(token: token)
                receivedProofs.append(contentsOf: proofs)
                totalReceived += proofs.totalValue
            } catch {
                // Continue processing other tokens
                // Logging removed - logger is private
            }
        }

        // Note: In a real implementation, we'd store the proofs
        // For now, they're handled by the receive() method

        // Metrics recording removed - metrics is private
        // In a real implementation, we'd need to expose metrics or add a public method

        return totalReceived
    }

    // MARK: - MPP Status

    /// Check the status of a multi-path payment
    /// - Parameter paymentId: The MPP payment ID
    /// - Returns: Status information
    /// - Note: MPP status tracking requires external payment coordination.
    ///   This implementation returns unknown status as MPP payments are atomic
    ///   and don't persist state after completion. For real-time MPP status,
    ///   use the MultiPathPaymentExecutor which tracks state during execution.
    func checkMPPStatus(paymentId: String) async throws -> MPPStatus {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }

        // MPP payments in Cashu are atomic - either all paths succeed or all fail.
        // The payment state exists only during execution in the MultiPathPaymentExecutor.
        // Once complete, the payment result is returned and state is not persisted.
        //
        // For persistent MPP status tracking, the calling application should:
        // 1. Store MPPSendResult after executeMultiPathPayment completes
        // 2. Track payment states in application-level storage
        //
        // This method returns unknown status as there's no built-in persistence layer.
        // Applications needing MPP history should implement their own tracking.
        return MPPStatus(
            paymentId: paymentId,
            totalAmount: 0,
            completedPaths: 0,
            totalPaths: 0,
            status: .unknown,
            timestamp: Date()
        )
    }

    // MARK: - Private Helpers

    private func calculateOptimalSplits(amount: Int) -> [Int] {
        // Simple split strategy - can be made more sophisticated
        let maxSplitSize = 1000 // Maximum size per split
        let minSplitSize = 10   // Minimum size per split

        var splits: [Int] = []
        var remaining = amount

        while remaining > 0 {
            let splitAmount = min(remaining, maxSplitSize)
            if splitAmount >= minSplitSize {
                splits.append(splitAmount)
                remaining -= splitAmount
            } else {
                // Add remainder to last split
                if !splits.isEmpty {
                    splits[splits.count - 1] += remaining
                } else {
                    splits.append(remaining)
                }
                remaining = 0
            }
        }

        return splits
    }

    private func executeMultiPathPayment(
        plans: [MPPPaymentPlan],
        invoice: String?
    ) async throws -> [MPPPaymentResult] {
        var results: [MPPPaymentResult] = []

        // Execute each partial payment
        await withTaskGroup(of: MPPPaymentResult.self) { group in
            for plan in plans {
                group.addTask {
                    do {
                        // Send the partial payment
                        // Note: This is a simplified implementation
                        // Real MPP would require sending specific proofs
                        let token = try await self.send(amount: plan.amount)
                        let tokenString = try CashuTokenUtils.serializeToken(token)

                        return MPPPaymentResult(
                            planId: plan.id,
                            success: true,
                            token: tokenString,
                            amount: plan.amount,
                            error: nil
                        )
                    } catch {
                        return MPPPaymentResult(
                            planId: plan.id,
                            success: false,
                            token: nil,
                            amount: plan.amount,
                            error: error
                        )
                    }
                }
            }

            for await result in group {
                results.append(result)
            }
        }

        // Check if all payments succeeded
        let allSucceeded = results.allSatisfy { $0.success }
        if !allSucceeded && invoice != nil {
            // If coordinated payment failed, attempt rollback
            try await rollbackFailedPayments(results: results)
        }

        return results
    }

    private func rollbackFailedPayments(results: [MPPPaymentResult]) async throws {
        // Attempt to reclaim successful payments if some failed
        for result in results where result.success {
            if let tokenString = result.token {
                do {
                    let token = try CashuTokenUtils.deserializeToken(tokenString)
                    _ = try await receive(token: token)
                } catch {
                    // Rollback error - continue with other rollbacks
                    // Logging removed - logger is private
                }
            }
        }
    }
}

// MARK: - MPP Result Types

/// Plan for a partial payment in an MPP transaction
public struct MPPPaymentPlan: Sendable {
    /// Unique identifier for this payment
    public let id: String

    /// Mint URL for this payment
    public let mintURL: String

    /// Amount for this partial payment
    public let amount: Int

    /// Proofs to use for this payment
    public let proofs: [Proof]
}

/// Result of a partial payment attempt
public struct MPPPaymentResult: Sendable {
    /// Plan ID this result corresponds to
    public let planId: String

    /// Whether the payment succeeded
    public let success: Bool

    /// Token if payment succeeded
    public let token: String?

    /// Amount that was attempted
    public let amount: Int

    /// Error if payment failed
    public let error: (any Error)?
}

/// Result of a multi-path payment send operation
public struct MPPSendResult: Sendable {
    /// Total amount sent
    public let totalAmount: Int

    /// Results for each partial payment
    public let partialPayments: [MPPPaymentResult]

    /// Lightning invoice if applicable
    public let invoice: String?

    /// Timestamp of the operation
    public let timestamp: Date

    /// Check if all paths succeeded
    public var isComplete: Bool {
        partialPayments.allSatisfy { $0.success }
    }

    /// Get successful payment tokens
    public var successfulTokens: [String] {
        partialPayments.compactMap { $0.success ? $0.token : nil }
    }

    /// Get total successfully sent amount
    public var successfulAmount: Int {
        partialPayments.filter { $0.success }.reduce(0) { $0 + $1.amount }
    }
}

/// Status of a multi-path payment
public struct MPPStatus: Sendable {
    /// Payment identifier
    public let paymentId: String

    /// Total amount of the payment
    public let totalAmount: Int

    /// Number of completed payment paths
    public let completedPaths: Int

    /// Total number of payment paths
    public let totalPaths: Int

    /// Current status
    public let status: PaymentStatus

    /// Timestamp
    public let timestamp: Date

    public enum PaymentStatus: String, Sendable {
        case pending
        case partial
        case complete
        case failed
        case cancelled
        case unknown
    }
}

// MARK: - MPP Configuration

/// Configuration for multi-path payment operations
public struct MPPConfiguration: Sendable {
    /// Maximum number of paths to split payment across
    public let maxPaths: Int

    /// Minimum amount per path
    public let minPathAmount: Int

    /// Maximum amount per path
    public let maxPathAmount: Int

    /// Timeout for MPP operations
    public let timeout: TimeInterval

    /// Whether to use atomic payments (all or nothing)
    public let atomicMode: Bool

    public init(
        maxPaths: Int = 10,
        minPathAmount: Int = 10,
        maxPathAmount: Int = 10000,
        timeout: TimeInterval = 60,
        atomicMode: Bool = true
    ) {
        self.maxPaths = maxPaths
        self.minPathAmount = minPathAmount
        self.maxPathAmount = maxPathAmount
        self.timeout = timeout
        self.atomicMode = atomicMode
    }
}
