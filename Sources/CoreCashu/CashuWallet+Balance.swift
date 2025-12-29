//
//  CashuWallet+Balance.swift
//  CoreCashu
//
//  Balance operations and denomination management for CashuWallet
//

import Foundation

// MARK: - Balance Operations

public extension CashuWallet {
    
    /// Get current wallet balance
    var balance: Int {
        get async throws {
            guard isReady else {
                throw CashuError.walletNotInitialized
            }
            
            return try await proofManager.getTotalBalance()
        }
    }
    
    /// Get balance by keyset
    func balance(for keysetID: String) async throws -> Int {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        
        return try await proofManager.getBalance(keysetID: keysetID)
    }
    
    /// Get detailed balance breakdown by keyset
    func getBalanceBreakdown() async throws -> BalanceBreakdown {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        
        let allProofs = try await proofManager.getAvailableProofs()
        let groupedProofs = allProofs.groupedByKeyset()
        
        var keysetBalances: [String: KeysetBalance] = [:]
        var totalBalance = 0
        
        for (keysetID, proofs) in groupedProofs {
            let keysetTotal = proofs.totalValue
            let denominationCounts = proofs.denominationCounts
            
            let keysetBalance = KeysetBalance(
                keysetID: keysetID,
                balance: keysetTotal,
                proofCount: proofs.count,
                denominations: denominationCounts,
                isActive: currentKeysetInfos[keysetID]?.active ?? false
            )
            
            keysetBalances[keysetID] = keysetBalance
            totalBalance += keysetTotal
        }
        
        return BalanceBreakdown(
            totalBalance: totalBalance,
            keysetBalances: keysetBalances,
            proofCount: allProofs.count
        )
    }
    
    /// Get real-time balance updates (for UI binding)
    func getBalanceStream() -> AsyncStream<BalanceUpdate> {
        return AsyncStream { continuation in
            Task {
                var lastBalance = 0
                
                while !Task.isCancelled {
                    do {
                        let currentBalance = try await self.balance
                        if currentBalance != lastBalance {
                            let update = BalanceUpdate(
                                newBalance: currentBalance,
                                previousBalance: lastBalance,
                                timestamp: Date()
                            )
                            continuation.yield(update)
                            lastBalance = currentBalance
                        }
                    } catch {
                        let errorUpdate = BalanceUpdate(
                            newBalance: lastBalance,
                            previousBalance: lastBalance,
                            timestamp: Date(),
                            error: error
                        )
                        continuation.yield(errorUpdate)
                    }
                    
                    // Check every 5 seconds
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
                
                continuation.finish()
            }
        }
    }
    
    /// Get all available proofs
    var proofs: [Proof] {
        get async throws {
            guard isReady else {
                throw CashuError.walletNotInitialized
            }
            
            return try await proofManager.getAvailableProofs()
        }
    }
}

// MARK: - Denomination Management

public extension CashuWallet {
    
    /// Get available denominations for the current wallet
    func getAvailableDenominations() async throws -> [Int] {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        
        let allProofs = try await proofManager.getAvailableProofs()
        let denominations = Set(allProofs.map { $0.amount })
        return Array(denominations).sorted()
    }
    
    /// Get denomination breakdown showing count of each denomination
    func getDenominationBreakdown() async throws -> DenominationBreakdown {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        
        let allProofs = try await proofManager.getAvailableProofs()
        let denominationCounts = allProofs.denominationCounts
        let totalValue = allProofs.totalValue
        
        return DenominationBreakdown(
            denominations: denominationCounts,
            totalValue: totalValue,
            totalProofs: allProofs.count
        )
    }
    
    /// Optimize denominations by swapping to preferred amounts
    /// - Parameter preferredDenominations: Target denominations to optimize for
    /// - Returns: Success status and new proofs from swap
    func optimizeDenominations(preferredDenominations: [Int]) async throws -> OptimizationResult {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        
        guard let swapService = swapService else {
            throw CashuError.walletNotInitialized
        }
        
        let allProofs = try await proofManager.getAvailableProofs()
        let currentDenominations = allProofs.denominationCounts
        let totalValue = allProofs.totalValue
        
        // Calculate optimal denomination distribution
        let optimalDistribution = calculateOptimalDistribution(
            totalValue: totalValue,
            preferredDenominations: preferredDenominations
        )
        
        // Check if optimization is needed
        let needsOptimization = !isDenominationOptimal(
            current: currentDenominations,
            optimal: optimalDistribution
        )
        
        if !needsOptimization {
            return OptimizationResult(
                success: true,
                proofsChanged: false,
                newProofs: [],
                previousDenominations: currentDenominations,
                newDenominations: currentDenominations
            )
        }
        
        // Perform swap using rotateTokens which swaps all proofs for fresh ones
        // This gives the mint the opportunity to return optimally-denominated proofs
        let swapResult = try await swapService.rotateTokens(
            proofs: allProofs,
            at: configuration.mintURL
        )
        
        // Update proof storage
        try await proofManager.removeProofs(allProofs)
        try await proofManager.addProofs(swapResult.newProofs)
        
        let newDenominations = swapResult.newProofs.denominationCounts
        
        return OptimizationResult(
            success: true,
            proofsChanged: true,
            newProofs: swapResult.newProofs,
            previousDenominations: currentDenominations,
            newDenominations: newDenominations
        )
    }
    
    /// Get recommended denomination structure for a given amount
    /// - Parameter amount: Target amount to optimize for
    /// - Returns: Recommended denomination breakdown
    func getRecommendedDenominations(for amount: Int) -> [Int: Int] {
        return DenominationUtils.getOptimalDenominations(amount: amount)
    }
}

// MARK: - Balance Management Types

/// Balance breakdown by keyset
public struct BalanceBreakdown: Sendable {
    public let totalBalance: Int
    public let keysetBalances: [String: KeysetBalance]
    public let proofCount: Int
    
    public init(totalBalance: Int, keysetBalances: [String: KeysetBalance], proofCount: Int) {
        self.totalBalance = totalBalance
        self.keysetBalances = keysetBalances
        self.proofCount = proofCount
    }
}

/// Balance information for a specific keyset
public struct KeysetBalance: Sendable {
    public let keysetID: String
    public let balance: Int
    public let proofCount: Int
    public let denominations: [Int: Int]
    public let isActive: Bool
    
    public init(keysetID: String, balance: Int, proofCount: Int, denominations: [Int: Int], isActive: Bool) {
        self.keysetID = keysetID
        self.balance = balance
        self.proofCount = proofCount
        self.denominations = denominations
        self.isActive = isActive
    }
}

/// Real-time balance update
public struct BalanceUpdate: Sendable {
    public let newBalance: Int
    public let previousBalance: Int
    public let timestamp: Date
    public let error: (any Error)?
    
    public init(newBalance: Int, previousBalance: Int, timestamp: Date, error: (any Error)? = nil) {
        self.newBalance = newBalance
        self.previousBalance = previousBalance
        self.timestamp = timestamp
        self.error = error
    }
    
    public var balanceChanged: Bool {
        return newBalance != previousBalance
    }
    
    public var balanceDifference: Int {
        return newBalance - previousBalance
    }
}

// MARK: - Denomination Management Types

/// Denomination breakdown
public struct DenominationBreakdown: Sendable {
    public let denominations: [Int: Int] // denomination -> count
    public let totalValue: Int
    public let totalProofs: Int
    
    public init(denominations: [Int: Int], totalValue: Int, totalProofs: Int) {
        self.denominations = denominations
        self.totalValue = totalValue
        self.totalProofs = totalProofs
    }
    
    public var availableDenominations: [Int] {
        return Array(denominations.keys).sorted()
    }
}

/// Result of denomination optimization
public struct OptimizationResult: Sendable {
    public let success: Bool
    public let proofsChanged: Bool
    public let newProofs: [Proof]
    public let previousDenominations: [Int: Int]
    public let newDenominations: [Int: Int]
    
    public init(
        success: Bool,
        proofsChanged: Bool,
        newProofs: [Proof],
        previousDenominations: [Int: Int],
        newDenominations: [Int: Int]
    ) {
        self.success = success
        self.proofsChanged = proofsChanged
        self.newProofs = newProofs
        self.previousDenominations = previousDenominations
        self.newDenominations = newDenominations
    }
}

// MARK: - Denomination Utilities

/// Utilities for denomination handling
public struct DenominationUtils {
    
    /// Standard Bitcoin-style denominations (powers of 2)
    public static let standardDenominations = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768]
    
    /// Get optimal denomination breakdown for an amount
    /// - Parameter amount: Amount to break down
    /// - Returns: Dictionary mapping denomination to count
    public static func getOptimalDenominations(amount: Int) -> [Int: Int] {
        guard amount > 0 else { return [:] }
        
        var remainingAmount = amount
        var result: [Int: Int] = [:]
        
        // Use greedy algorithm with largest denominations first
        let sortedDenominations = standardDenominations.sorted(by: >)
        
        for denomination in sortedDenominations {
            if remainingAmount >= denomination {
                let count = remainingAmount / denomination
                result[denomination] = count
                remainingAmount -= count * denomination
                
                if remainingAmount == 0 {
                    break
                }
            }
        }
        
        return result
    }
    
    /// Calculate efficiency of denomination breakdown
    /// - Parameter denominations: Current denomination breakdown
    /// - Returns: Efficiency score (0.0 to 1.0, higher is better)
    public static func calculateEfficiency(_ denominations: [Int: Int]) -> Double {
        let totalProofs = denominations.values.reduce(0, +)
        let totalValue = denominations.reduce(0) { result, pair in
            result + (pair.key * pair.value)
        }
        
        guard totalValue > 0 else { return 0.0 }
        
        // Calculate optimal proof count for this value
        let optimalBreakdown = getOptimalDenominations(amount: totalValue)
        let optimalProofCount = optimalBreakdown.values.reduce(0, +)
        
        // Efficiency = optimal / actual (lower proof count is better)
        return Double(optimalProofCount) / Double(totalProofs)
    }
    
    /// Check if denomination breakdown is close to optimal
    /// - Parameters:
    ///   - current: Current denomination breakdown
    ///   - threshold: Efficiency threshold (0.0 to 1.0)
    /// - Returns: True if denomination is efficient enough
    public static func isEfficient(_ current: [Int: Int], threshold: Double = 0.8) -> Bool {
        return calculateEfficiency(current) >= threshold
    }
}

// MARK: - Collection Extensions for Denominations

extension Collection where Element == Proof {
    /// Get denomination counts from proofs
    public var denominationCounts: [Int: Int] {
        var counts: [Int: Int] = [:]
        for proof in self {
            counts[proof.amount, default: 0] += 1
        }
        return counts
    }
}
