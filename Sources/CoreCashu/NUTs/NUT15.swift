//
//  NUT15.swift
//  CashuKit
//
//  NUT-15: Partial multi-path payments
//  https://github.com/cashubtc/nuts/blob/main/15.md
//

import Foundation

// MARK: - NUT-15: Partial multi-path payments

/// NUT-15: Partial multi-path payments
/// This NUT defines how wallets can instruct multiple mints to each pay a partial amount of a Lightning invoice

// MARK: - MPP Types

/// Options for multi-path payment in melt quote request
public struct MPPOptions: CashuCodabale {
    /// Partial amount for the requested payment in millisats (msat)
    public let amount: Int
    
    public init(amount: Int) {
        self.amount = amount
    }
}

/// Options structure for PostMeltQuoteBolt11Request
public struct MeltQuoteOptions: CashuCodabale {
    /// Multi-path payment options
    public let mpp: MPPOptions?
    
    public init(mpp: MPPOptions? = nil) {
        self.mpp = mpp
    }
}

/// Extended melt quote request for BOLT11 with MPP support
public struct PostMeltQuoteBolt11Request: CashuCodabale {
    /// BOLT11 Lightning invoice to be paid
    public let request: String
    
    /// Unit the wallet would like to pay with
    public let unit: String
    
    /// Optional parameters including MPP
    public let options: MeltQuoteOptions?
    
    public init(request: String, unit: String, options: MeltQuoteOptions? = nil) {
        self.request = request
        self.unit = unit
        self.options = options
    }
    
    /// Create a request with MPP for partial payment
    public static func withMPP(
        request: String,
        unit: String,
        partialAmountMsat: Int
    ) -> PostMeltQuoteBolt11Request {
        let mppOptions = MPPOptions(amount: partialAmountMsat)
        let options = MeltQuoteOptions(mpp: mppOptions)
        return PostMeltQuoteBolt11Request(
            request: request,
            unit: unit,
            options: options
        )
    }
    
    /// Validate the request structure
    public func validate() -> Bool {
        guard !request.isEmpty, !unit.isEmpty else { return false }
        
        // Validate MPP amount if present
        if let mppAmount = options?.mpp?.amount {
            guard mppAmount > 0 else { return false }
        }
        
        return true
    }
    
    /// Check if this is an MPP request
    public var isMPPRequest: Bool {
        return options?.mpp != nil
    }
    
    /// Get partial amount in millisats if MPP
    public var partialAmountMsat: Int? {
        return options?.mpp?.amount
    }
}

// MARK: - MPP Settings

/// Method and unit pair for MPP support
public struct MPPMethodUnit: CashuCodabale {
    public let method: String
    public let unit: String
    
    public init(method: String, unit: String) {
        self.method = method
        self.unit = unit
    }
}

/// NUT-15 settings from mint info
public struct NUT15Settings: CashuCodabale {
    /// Array of method-unit pairs that support MPP
    public let methods: [MPPMethodUnit]
    
    public init(methods: [MPPMethodUnit]) {
        self.methods = methods
    }
    
    /// Check if a specific method-unit pair supports MPP
    public func supportsMPP(method: String, unit: String) -> Bool {
        return methods.contains { $0.method == method && $0.unit == unit }
    }
    
    /// Get all supported methods
    public var supportedMethods: [String] {
        return Array(Set(methods.map { $0.method }))
    }
    
    /// Get all supported units
    public var supportedUnits: [String] {
        return Array(Set(methods.map { $0.unit }))
    }
}

// MARK: - Multi-mint Payment Coordination

/// Represents a partial payment plan for one mint
public struct PartialPaymentPlan: Sendable {
    /// The mint URL
    public let mintURL: String
    
    /// Partial amount to pay from this mint (in base unit)
    public let amount: Int
    
    /// Proofs to use for this payment
    public let proofs: [Proof]
    
    /// The unit for this payment
    public let unit: String
    
    public init(mintURL: String, amount: Int, proofs: [Proof], unit: String) {
        self.mintURL = mintURL
        self.amount = amount
        self.proofs = proofs
        self.unit = unit
    }
    
    /// Total value of the proofs
    public var proofsTotal: Int {
        return proofs.reduce(0) { $0 + $1.amount }
    }
    
    /// Validate the payment plan
    public func validate() -> Bool {
        guard amount > 0,
              !proofs.isEmpty,
              proofsTotal >= amount,
              !mintURL.isEmpty,
              !unit.isEmpty else {
            return false
        }
        return true
    }
}

/// Result of a partial payment attempt
public struct PartialPaymentResult: Sendable {
    /// The mint URL
    public let mintURL: String
    
    /// Whether the payment was successful
    public let success: Bool
    
    /// Error if payment failed
    public let error: (any Error)?
    
    /// Change proofs if any
    public let change: [Proof]?
    
    /// Fee paid for this partial payment
    public let feePaid: Int
    
    public init(
        mintURL: String,
        success: Bool,
        error: (any Error)? = nil,
        change: [Proof]? = nil,
        feePaid: Int = 0
    ) {
        self.mintURL = mintURL
        self.success = success
        self.error = error
        self.change = change
        self.feePaid = feePaid
    }
}

/// Coordinates multi-path payments across multiple mints
public struct MultiPathPaymentCoordinator: Sendable {
    
    /// Split a total amount into partial amounts based on available balances
    /// - Parameters:
    ///   - totalAmount: Total amount to pay
    ///   - availableBalances: Dictionary of mint URL to available balance
    /// - Returns: Dictionary of mint URL to partial amount to pay
    public static func splitAmount(
        totalAmount: Int,
        availableBalances: [String: Int]
    ) throws -> [String: Int] {
        // Validate inputs
        guard totalAmount > 0 else {
            throw CashuError.invalidAmount
        }
        
        let totalAvailable = availableBalances.values.reduce(0, +)
        guard totalAvailable >= totalAmount else {
            throw CashuError.balanceInsufficient
        }
        
        var remaining = totalAmount
        var allocations: [String: Int] = [:]
        
        // Sort mints by available balance (largest first)
        let sortedMints = availableBalances.sorted { $0.value > $1.value }
        
        // Allocate amounts starting with largest balances
        for (mint, balance) in sortedMints {
            guard remaining > 0 else { break }
            
            let allocation = min(balance, remaining)
            if allocation > 0 {
                allocations[mint] = allocation
                remaining -= allocation
            }
        }
        
        // Ensure we allocated the full amount
        guard remaining == 0 else {
            throw CashuError.invalidAmount
        }
        
        return allocations
    }
    
    /// Convert base unit amount to millisats for Lightning
    /// - Parameters:
    ///   - amount: Amount in base unit (e.g., sats)
    ///   - unit: The unit being used
    /// - Returns: Amount in millisats
    public static func toMillisats(amount: Int, unit: String) -> Int {
        switch unit.lowercased() {
        case "sat":
            return amount * 1000
        case "msat":
            return amount
        default:
            // For other units, assume they need conversion to sats first
            // This would need proper unit conversion logic
            return amount * 1000
        }
    }
    
    /// Validate that all mints support MPP for the given method and unit
    /// - Parameters:
    ///   - mintURLs: List of mint URLs to validate
    ///   - method: Payment method (e.g., "bolt11")
    ///   - unit: Payment unit (e.g., "sat")
    ///   - mintInfos: Dictionary of mint URL to MintInfo
    /// - Returns: True if all mints support MPP
    public static func validateMPPSupport(
        mintURLs: [String],
        method: String,
        unit: String,
        mintInfos: [String: MintInfo]
    ) -> Bool {
        for mintURL in mintURLs {
            guard let mintInfo = mintInfos[mintURL],
                  let nut15Settings = mintInfo.getNUT15Settings(),
                  nut15Settings.supportsMPP(method: method, unit: unit) else {
                return false
            }
        }
        return true
    }
}

// MARK: - CashuWallet Extensions

extension CashuWallet {
    
    /// Execute a multi-path payment across multiple mints
    /// - Parameters:
    ///   - invoice: BOLT11 Lightning invoice to pay
    ///   - paymentPlans: Array of partial payment plans for each mint
    ///   - timeout: Timeout for the entire MPP operation
    /// - Returns: Array of partial payment results
    /// - Note: Due to the atomic nature of MPP, either all payments succeed or all fail
    public func executeMultiPathPayment(
        invoice: String,
        paymentPlans: [PartialPaymentPlan],
        timeout: TimeInterval = 60
    ) async throws -> [PartialPaymentResult] {
        // Create executor with configuration
        let config = MultiPathPaymentExecutor.Configuration(
            timeout: timeout,
            optimisticMode: true
        )
        let executor = MultiPathPaymentExecutor(configuration: config)
        
        // Create wallet mapping - in this case, all plans use the same wallet instance
        var wallets: [String: CashuWallet] = [:]
        for plan in paymentPlans {
            wallets[plan.mintURL] = self
        }
        
        // Execute the multi-path payment
        return try await executor.execute(
            invoice: invoice,
            paymentPlans: paymentPlans,
            wallets: wallets
        )
    }
    
    /// Request a melt quote with MPP support
    /// - Parameters:
    ///   - invoice: BOLT11 Lightning invoice
    ///   - partialAmountMsat: Partial amount in millisats
    ///   - unit: The unit to use for the payment
    /// - Returns: Melt quote response
    public func requestMeltQuoteWithMPP(
        invoice: String,
        partialAmountMsat: Int,
        unit: String
    ) async throws -> PostMeltQuoteResponse {
        // Create a new MeltService instance for this operation
        let meltService = await MeltService()
        
        return try await meltService.requestMeltQuoteWithMPP(
            request: invoice,
            partialAmountMsat: partialAmountMsat,
            unit: unit,
            at: mintURL
        )
    }
    
    /// Create a multi-path payment plan for an invoice
    /// - Parameters:
    ///   - invoice: BOLT11 Lightning invoice to pay
    ///   - totalAmount: Total amount to pay
    ///   - mints: Dictionary of mint URLs to their capabilities
    ///   - unit: The unit to use for the payment
    ///   - strategy: Optimization strategy to use
    /// - Returns: Array of partial payment plans
    public func createMultiPathPaymentPlan(
        invoice: String,
        totalAmount: Int,
        mints: [String: MintCapability],
        unit: String,
        strategy: PaymentPathOptimizer.OptimizationStrategy = .minimizeMints
    ) async throws -> [PartialPaymentPlan] {
        // Optimize the payment paths
        let allocations = try PaymentPathOptimizer.optimize(
            amount: totalAmount,
            availableMints: mints,
            strategy: strategy
        )
        
        // Create payment plans for each allocation
        var plans: [PartialPaymentPlan] = []
        
        for (mintURL, amount) in allocations {
            // Select proofs for this mint
            // In a real implementation, this would query the wallet's proof storage
            let proofs = try await selectProofsForAmount(amount, mintURL: mintURL)
            
            let plan = PartialPaymentPlan(
                mintURL: mintURL,
                amount: amount,
                proofs: proofs,
                unit: unit
            )
            
            plans.append(plan)
        }
        
        return plans
    }
    
    /// Select proofs for a specific amount from a mint
    private func selectProofsForAmount(_ amount: Int, mintURL: String) async throws -> [Proof] {
        // Verify this wallet is configured for the requested mint
        guard self.mintURL == mintURL else {
            // In a multi-mint wallet setup, we would need to have separate wallet instances
            // or a more sophisticated proof storage system that tracks mint URLs
            throw CashuError.invalidMintConfiguration
        }
        
        // Use the wallet's existing proof selection mechanism
        // This will select optimal proofs from the wallet's proof storage
        let selectedProofs = try await selectProofsForAmount(amount)
        
        // In a real multi-mint implementation, we would filter these proofs
        // to ensure they belong to the specified mint. For now, since
        // each wallet instance is tied to a single mint, all proofs
        // should be from the correct mint.
        
        return selectedProofs
    }
}

// MARK: - MintInfo Extensions

extension MintInfo {
    /// Check if the mint supports NUT-15 (Multi-path payments)
    public var supportsMPP: Bool {
        return supportsNUT("15")
    }
    
    /// Get NUT-15 settings if supported
    public func getNUT15Settings() -> NUT15Settings? {
        guard let nut15Data = nuts?["15"]?.dictionaryValue else { return nil }
        
        guard let methodsData = nut15Data["methods"] as? [[String: Any]] else {
            return NUT15Settings(methods: [])
        }
        
        let methods = methodsData.compactMap { methodDict -> MPPMethodUnit? in
            guard let method = methodDict["method"] as? String,
                  let unit = methodDict["unit"] as? String else {
                return nil
            }
            
            return MPPMethodUnit(method: method, unit: unit)
        }
        
        return NUT15Settings(methods: methods)
    }
    
    /// Check if mint supports MPP for specific method and unit
    public func supportsMPP(method: String, unit: String) -> Bool {
        guard let settings = getNUT15Settings() else { return false }
        return settings.supportsMPP(method: method, unit: unit)
    }
}

// MARK: - Error Extensions

extension CashuError {
    /// Check if this error indicates MPP is not supported
    public var isMPPNotSupported: Bool {
        if case .unsupportedOperation(let message) = self {
            return message.contains("Multi-path payment") || message.contains("MPP")
        }
        return false
    }
}