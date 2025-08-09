//
//  NUT05.swift
//  CashuKit
//
//  NUT-05: Melting tokens
//  https://github.com/cashubtc/nuts/blob/main/05.md
//

import Foundation
@preconcurrency import P256K

// MARK: - NUT-05: Melting tokens

/// NUT-05: Melting tokens
/// This NUT defines the melting operation for spending tokens through external payments

// MARK: - Common Types

/// Payment method supported by the mint
public enum PaymentMethod: String, CaseIterable, CashuCodabale {
    case bolt11 = "bolt11"
    case bolt12 = "bolt12"
    
    /// Human-readable description
    public var description: String {
        switch self {
        case .bolt11: return "Lightning Network BOLT11"
        case .bolt12: return "Lightning Network BOLT12"
        }
    }
}

/// Melt quote state as defined in NUT-05
public enum MeltQuoteState: String, CaseIterable, CashuCodabale {
    case unpaid = "UNPAID"     // Request has not been paid yet
    case pending = "PENDING"   // Request is currently being paid
    case paid = "PAID"         // Request has been paid successfully
    
    /// Whether the quote is in a final state
    public var isFinal: Bool {
        return self == .paid
    }
    
    /// Whether payment is still possible
    public var canPay: Bool {
        return self == .unpaid
    }
}

// MARK: - Request/Response Structures

/// Base structure for requesting a melt quote
public struct PostMeltQuoteRequest: CashuCodabale {
    public let request: String
    public let unit: String
    
    public init(request: String, unit: String) {
        self.request = request
        self.unit = unit
    }
    
    /// Validate the melt quote request structure
    public func validate() -> Bool {
        guard !request.isEmpty, !unit.isEmpty else { return false }
        return true
    }
}

/// Base structure for melt quote response
public struct PostMeltQuoteResponse: CashuCodabale {
    public let quote: String
    public let amount: Int
    public let unit: String
    public let state: MeltQuoteState
    public let expiry: Int
    public let feeReserve: Int?
    
    private enum CodingKeys: String, CodingKey {
        case quote
        case amount
        case unit
        case state
        case expiry
        case feeReserve = "fee_reserve"
    }
    
    public init(quote: String, amount: Int, unit: String, state: MeltQuoteState, expiry: Int, feeReserve: Int? = nil) {
        self.quote = quote
        self.amount = amount
        self.unit = unit
        self.state = state
        self.expiry = expiry
        self.feeReserve = feeReserve
    }
    
    /// Validate the melt quote response structure
    public func validate() -> Bool {
        guard !quote.isEmpty,
              amount > 0,
              !unit.isEmpty,
              expiry > 0 else {
            return false
        }
        return true
    }
    
    /// Check if the quote has expired
    public var isExpired: Bool {
        return Int(Date().timeIntervalSince1970) > expiry
    }
    
    /// Time until expiry in seconds
    public var timeUntilExpiry: Int {
        return max(0, expiry - Int(Date().timeIntervalSince1970))
    }
    
    /// Whether this quote supports fee return (NUT-08)
    public var supportsFeeReturn: Bool {
        return (feeReserve ?? 0) > 0
    }
    
    /// Recommended number of blank outputs for fee return (NUT-08)
    public var recommendedBlankOutputs: Int {
        guard let feeReserve = feeReserve, feeReserve > 0 else { return 0 }
        return FeeReturnCalculator.calculateBlankOutputCount(feeReserve: feeReserve)
    }
    
    /// Total amount needed including fee reserve (NUT-08)
    public var totalAmountWithFeeReserve: Int {
        return amount + (feeReserve ?? 0)
    }
}

/// Request structure for executing a melt
public struct PostMeltRequest: CashuCodabale {
    public let quote: String
    public let inputs: [Proof]
    public let outputs: [BlindedMessage]?
    
    public init(quote: String, inputs: [Proof], outputs: [BlindedMessage]? = nil) {
        self.quote = quote
        self.inputs = inputs
        self.outputs = outputs
    }
    
    /// Validate the melt request structure
    public func validate() -> Bool {
        guard !quote.isEmpty, !inputs.isEmpty else { return false }
        
        // Basic validation for inputs
        for input in inputs {
            guard input.amount > 0,
                  !input.id.isEmpty,
                  !input.secret.isEmpty,
                  !input.C.isEmpty else {
                return false
            }
        }
        
        // Validate outputs if provided (NUT-08)
        if let outputs = outputs {
            for output in outputs {
                guard let outputId = output.id, !outputId.isEmpty,
                      !output.B_.isEmpty else {
                    return false
                }
            }
        }
        
        return true
    }
    
    /// Get total input amount
    public var totalInputAmount: Int {
        return inputs.reduce(0) { $0 + $1.amount }
    }
    
    /// Number of blank outputs provided for fee return (NUT-08)
    public var blankOutputCount: Int {
        return outputs?.count ?? 0
    }
    
    /// Whether this request supports fee return (NUT-08)
    public var supportsFeeReturn: Bool {
        return !(outputs ?? []).isEmpty
    }
}

/// Response structure for executing a melt
public struct PostMeltResponse: CashuCodabale {
    public let state: MeltQuoteState
    public let change: [BlindSignature]?
    
    public init(state: MeltQuoteState, change: [BlindSignature]? = nil) {
        self.state = state
        self.change = change
    }
    
    /// Validate the melt response structure
    public func validate() -> Bool {
        // If change is provided, validate it
        if let change = change {
            for signature in change {
                guard signature.amount > 0,
                      !signature.id.isEmpty,
                      !signature.C_.isEmpty else {
                    return false
                }
            }
        }
        
        return true
    }
    
    /// Get total change amount
    public var totalChangeAmount: Int {
        return change?.reduce(0) { $0 + $1.amount } ?? 0
    }
    
    /// Whether fees were returned (NUT-08)
    public var hasFeesReturned: Bool {
        return !(change ?? []).isEmpty
    }
    
    /// Number of change signatures returned (NUT-08)
    public var changeSignatureCount: Int {
        return change?.count ?? 0
    }
}

// MARK: - Melt Operation Types

/// Type of melt operation
public enum MeltType: String, CaseIterable, Sendable {
    case payment = "payment"           // External payment
    case withdrawal = "withdrawal"     // Withdraw from mint
    case refund = "refund"            // Refund failed payment
}

/// Melt operation result
public struct MeltResult: Sendable {
    public let state: MeltQuoteState
    public let changeProofs: [Proof]
    public let spentProofs: [Proof]
    public let meltType: MeltType
    public let totalAmount: Int
    public let fees: Int
    public let paymentProof: Data?
    
    public init(state: MeltQuoteState, changeProofs: [Proof], spentProofs: [Proof], meltType: MeltType, totalAmount: Int, fees: Int, paymentProof: Data? = nil) {
        self.state = state
        self.changeProofs = changeProofs
        self.spentProofs = spentProofs
        self.meltType = meltType
        self.totalAmount = totalAmount
        self.fees = fees
        self.paymentProof = paymentProof
    }
    
    /// Whether the payment was successful
    public var isSuccessful: Bool {
        return state == .paid
    }
    
    /// Net amount spent (total - change)
    public var netAmountSpent: Int {
        let changeAmount = changeProofs.reduce(0) { $0 + $1.amount }
        return totalAmount - changeAmount
    }
}

/// Melt preparation result
public struct MeltPreparation: Sendable {
    public let quote: PostMeltQuoteResponse
    public let inputProofs: [Proof]
    public let blindedMessages: [BlindedMessage]?
    public let blindingData: [WalletBlindingData]?
    public let requiredAmount: Int
    public let changeAmount: Int
    public let fees: Int
    
    public init(quote: PostMeltQuoteResponse, inputProofs: [Proof], blindedMessages: [BlindedMessage]? = nil, blindingData: [WalletBlindingData]? = nil, requiredAmount: Int, changeAmount: Int, fees: Int) {
        self.quote = quote
        self.inputProofs = inputProofs
        self.blindedMessages = blindedMessages
        self.blindingData = blindingData
        self.requiredAmount = requiredAmount
        self.changeAmount = changeAmount
        self.fees = fees
    }
}

// MARK: - Settings Support

/// Method-specific settings for melting
public struct MeltMethodSetting: CashuCodabale {
    public let method: String
    public let unit: String
    public let minAmount: Int?
    public let maxAmount: Int?
    public let options: [String: AnyCodable]?
    
    public init(method: String, unit: String, minAmount: Int? = nil, maxAmount: Int? = nil, options: [String: AnyCodable]? = nil) {
        self.method = method
        self.unit = unit
        self.minAmount = minAmount
        self.maxAmount = maxAmount
        self.options = options
    }
    
    private enum CodingKeys: String, CodingKey {
        case method
        case unit
        case minAmount = "min_amount"
        case maxAmount = "max_amount"
        case options
    }
}

/// NUT-05 mint settings
public struct MeltSettings: CashuCodabale {
    public let methods: [MeltMethodSetting]
    public let disabled: Bool
    
    public init(methods: [MeltMethodSetting], disabled: Bool = false) {
        self.methods = methods
        self.disabled = disabled
    }
    
    /// Get supported method-unit pairs
    public var supportedPairs: [(method: String, unit: String)] {
        return methods.map { ($0.method, $0.unit) }
    }
    
    /// Check if a method-unit pair is supported
    public func supports(method: String, unit: String) -> Bool {
        return methods.contains { $0.method == method && $0.unit == unit }
    }
    
    /// Get settings for a specific method-unit pair
    public func getSettings(for method: String, unit: String) -> MeltMethodSetting? {
        return methods.first { $0.method == method && $0.unit == unit }
    }
}

// MARK: - Melt Service

@CashuActor
public struct MeltService: Sendable {
    private let router: NetworkRouter<MeltAPI>
    private let keyExchangeService: KeyExchangeService
    private let keysetManagementService: KeysetManagementService
    
    public init() async {
        self.router = NetworkRouter<MeltAPI>(decoder: .cashuDecoder)
        self.router.delegate = CashuEnvironment.current.routerDelegate
        self.keyExchangeService = await KeyExchangeService()
        self.keysetManagementService = await KeysetManagementService()
    }
    
    /// Request a melt quote for a payment request
    /// - parameters:
    ///   - request: The payment request (e.g., Lightning invoice)
    ///   - method: Payment method
    ///   - unit: Currency unit
    ///   - mintURL: The base URL of the mint
    /// - returns: PostMeltQuoteResponse with quote information
    public func requestMeltQuote(
        request: String,
        method: PaymentMethod,
        unit: String,
        at mintURL: String
    ) async throws -> PostMeltQuoteResponse {
        let quoteRequest = PostMeltQuoteRequest(request: request, unit: unit)
        
        // Enhanced validation using NUTValidation
        let validation = NUTValidation.validateMeltQuoteRequest(quoteRequest)
        guard validation.isValid else {
            throw CashuError.validationFailed
        }
        
        // Setup networking
        let normalizedURL = try ValidationUtils.normalizeMintURL(mintURL)
        CashuEnvironment.current.setup(baseURL: normalizedURL)
        
        // Request quote
        return try await router.execute(.requestMeltQuote(method.rawValue, quoteRequest))
    }
    
    /// Request a melt quote with MPP support (NUT-15)
    /// - parameters:
    ///   - request: The payment request (e.g., Lightning invoice)
    ///   - partialAmountMsat: Partial amount in millisats for MPP
    ///   - unit: Currency unit
    ///   - mintURL: The base URL of the mint
    /// - returns: PostMeltQuoteResponse with quote information
    public func requestMeltQuoteWithMPP(
        request: String,
        partialAmountMsat: Int,
        unit: String,
        at mintURL: String
    ) async throws -> PostMeltQuoteResponse {
        let quoteRequest = PostMeltQuoteBolt11Request.withMPP(
            request: request,
            unit: unit,
            partialAmountMsat: partialAmountMsat
        )
        
        // Validate request
        guard quoteRequest.validate() else {
            throw CashuError.validationFailed
        }
        
        // Setup networking
        let normalizedURL = try ValidationUtils.normalizeMintURL(mintURL)
        CashuEnvironment.current.setup(baseURL: normalizedURL)
        
        // Request quote with MPP
        return try await router.execute(.requestMeltQuoteWithMPP("bolt11", quoteRequest))
    }
    
    /// Check the state of a melt quote
    /// - parameters:
    ///   - quoteID: The quote ID to check
    ///   - method: Payment method
    ///   - mintURL: The base URL of the mint
    /// - returns: PostMeltQuoteResponse with current state
    public func checkMeltQuote(
        quoteID: String,
        method: PaymentMethod,
        at mintURL: String
    ) async throws -> PostMeltQuoteResponse {
        // Setup networking
        let normalizedURL = try ValidationUtils.normalizeMintURL(mintURL)
        CashuEnvironment.current.setup(baseURL: normalizedURL)
        
        return try await router.execute(.checkMeltQuote(method.rawValue, quoteID))
    }
    
    /// Execute a melt operation
    /// - parameters:
    ///   - request: The melt request with quote and inputs
    ///   - method: Payment method
    ///   - mintURL: The base URL of the mint
    /// - returns: PostMeltResponse with payment state
    public func executeMelt(
        _ request: PostMeltRequest,
        method: PaymentMethod,
        at mintURL: String
    ) async throws -> PostMeltResponse {
        // Validate request
        // Enhanced validation
        guard request.validate() else {
            throw CashuError.validationFailed
        }
        
        // Validate inputs array
        let inputValidation = NUTValidation.validateProofs(request.inputs)
        guard inputValidation.isValid else {
            throw CashuError.validationFailed
        }
        
        // Validate quote ID
        let quoteValidation = NUTValidation.validateQuoteID(request.quote)
        guard quoteValidation.isValid else {
            throw CashuError.validationFailed
        }
        
        // Setup networking
        let normalizedURL = try ValidationUtils.normalizeMintURL(mintURL)
        CashuEnvironment.current.setup(baseURL: normalizedURL)
        
        // Execute melt (this may block for external payments)
        return try await router.execute(.executeMelt(method.rawValue, request))
    }
    
    /// Prepare a melt operation by selecting optimal proofs and creating change outputs
    /// - parameters:
    ///   - paymentRequest: The payment request to melt for
    ///   - method: Payment method
    ///   - unit: Currency unit
    ///   - availableProofs: Available proofs in wallet
    ///   - mintURL: The base URL of the mint
    /// - returns: MeltPreparation with prepared inputs and outputs
    public func prepareMelt(
        paymentRequest: String,
        method: PaymentMethod,
        unit: String,
        availableProofs: [Proof],
        at mintURL: String
    ) async throws -> MeltPreparation {
        // Request quote first
        let quote = try await requestMeltQuote(
            request: paymentRequest,
            method: method,
            unit: unit,
            at: mintURL
        )
        
        // Get keyset information for fee calculation
        let keysetResponse = try await keysetManagementService.getKeysets(from: mintURL)
        let keysetDict = Dictionary(uniqueKeysWithValues: keysetResponse.keysets.map { ($0.id, $0) })
        
        // Select optimal proofs for the required amount
        let selectionResult = try await keysetManagementService.calculateOptimalProofSelection(
            availableProofs: availableProofs,
            targetAmount: quote.amount,
            from: mintURL
        )
        
        guard let selection = selectionResult.recommended else {
            throw CashuError.insufficientFunds
        }
        
        // Calculate fees
        let fees = FeeCalculator.calculateFees(for: selection.selectedProofs, keysetInfo: keysetDict)
        let totalInput = selection.totalAmount
        let requiredAmount = quote.amount + fees
        
        guard totalInput >= requiredAmount else {
            throw CashuError.insufficientFunds
        }
        
        let changeAmount = totalInput - requiredAmount
        
        // Create change outputs if needed
        var blindedMessages: [BlindedMessage]?
        var blindingData: [WalletBlindingData]?
        
        if changeAmount > 0 {
            // Create optimal denominations for change
            let changeAmounts = createOptimalDenominations(for: changeAmount)
            
            // Get active keyset for outputs
            let activeKeysets = try await keysetManagementService.getActiveKeysets(from: mintURL)
            
            // Filter keysets by unit
            let unitKeysets = activeKeysets.filter { $0.unit == unit }
            
            guard let activeKeyset = unitKeysets.first else {
                // Provide more specific error based on whether any keysets exist
                if activeKeysets.isEmpty {
                    throw CashuError.noActiveKeyset
                } else {
                    throw CashuError.keysetInactive
                }
            }
            
            // Create blinded messages for change
            var messages: [BlindedMessage] = []
            var blindings: [WalletBlindingData] = []
            
            for amount in changeAmounts {
                let secret = CashuKeyUtils.generateRandomSecret()
                let walletBlindingData = try WalletBlindingData(secret: secret)
                let blindedMessage = BlindedMessage(
                    amount: amount,
                    id: activeKeyset.id,
                    B_: walletBlindingData.blindedMessage.dataRepresentation.hexString
                )
                
                messages.append(blindedMessage)
                blindings.append(walletBlindingData)
            }
            
            blindedMessages = messages
            blindingData = blindings
        }
        
        return MeltPreparation(
            quote: quote,
            inputProofs: selection.selectedProofs,
            blindedMessages: blindedMessages,
            blindingData: blindingData,
            requiredAmount: requiredAmount,
            changeAmount: changeAmount,
            fees: fees
        )
    }
    
    /// Execute a complete melt operation (prepare + execute + unblind change)
    /// - parameters:
    ///   - preparation: Prepared melt data
    ///   - method: Payment method
    ///   - mintURL: The base URL of the mint
    /// - returns: MeltResult with payment outcome
    public func executeCompleteMelt(
        preparation: MeltPreparation,
        method: PaymentMethod,
        at mintURL: String
    ) async throws -> MeltResult {
        // Create melt request
        let request = PostMeltRequest(
            quote: preparation.quote.quote,
            inputs: preparation.inputProofs
        )
        
        // Execute melt
        let response = try await executeMelt(request, method: method, at: mintURL)
        
        // Validate response
        guard response.validate() else {
            throw CashuError.invalidResponse
        }
        
        // Unblind change if present
        var changeProofs: [Proof] = []
        
        if let changeSignatures = response.change,
           let _ = preparation.blindedMessages,
           let blindingData = preparation.blindingData {
            
            guard changeSignatures.count == blindingData.count else {
                throw CashuError.invalidResponse
            }
            
            // Get mint public keys for unblinding
            let keyResponse = try await keyExchangeService.getKeys(from: mintURL)
            let mintKeys = Dictionary(uniqueKeysWithValues: keyResponse.keysets.flatMap { keyset in
                keyset.keys.compactMap { (amountStr, publicKeyHex) -> (String, P256K.KeyAgreement.PublicKey)? in
                    guard let amount = Int(amountStr),
                          let publicKeyData = Data(hexString: publicKeyHex),
                          let publicKey = try? P256K.KeyAgreement.PublicKey(dataRepresentation: publicKeyData, format: .compressed) else {
                        return nil
                    }
                    return ("\(keyset.id)_\(amount)", publicKey)
                }
            })
            
            // Unblind signatures to create change proofs
            for (index, signature) in changeSignatures.enumerated() {
                let blindingDataItem = blindingData[index]
                let mintKeyKey = "\(signature.id)_\(signature.amount)"
                
                guard let mintPublicKey = mintKeys[mintKeyKey] else {
                    throw CashuError.invalidSignature("Mint public key not found for amount \(signature.amount)")
                }
                
                guard let blindedSignatureData = Data(hexString: signature.C_) else {
                    throw CashuError.invalidHexString
                }
                
                let unblindedToken = try Wallet.unblindSignature(
                    blindedSignature: blindedSignatureData,
                    blindingData: blindingDataItem,
                    mintPublicKey: mintPublicKey
                )
                
                let proof = Proof(
                    amount: signature.amount,
                    id: signature.id,
                    secret: unblindedToken.secret,
                    C: unblindedToken.signature.hexString
                )
                
                changeProofs.append(proof)
            }
        }
        
        return MeltResult(
            state: response.state,
            changeProofs: changeProofs,
            spentProofs: preparation.inputProofs,
            meltType: .payment,
            totalAmount: preparation.inputProofs.reduce(0) { $0 + $1.amount },
            fees: preparation.fees
        )
    }
    
    /// Simple melt operation for external payments
    /// - parameters:
    ///   - paymentRequest: The payment request to pay
    ///   - method: Payment method
    ///   - unit: Currency unit
    ///   - availableProofs: Available proofs in wallet
    ///   - mintURL: The base URL of the mint
    /// - returns: MeltResult with payment outcome
    public func meltToPayment(
        paymentRequest: String,
        method: PaymentMethod,
        unit: String,
        from availableProofs: [Proof],
        at mintURL: String
    ) async throws -> MeltResult {
        let preparation = try await prepareMelt(
            paymentRequest: paymentRequest,
            method: method,
            unit: unit,
            availableProofs: availableProofs,
            at: mintURL
        )
        
        return try await executeCompleteMelt(
            preparation: preparation,
            method: method,
            at: mintURL
        )
    }
    
    // MARK: - NUT-08: Fee Return Methods
    
    /// Prepare a melt operation with fee return support (NUT-08)
    /// - parameters:
    ///   - paymentRequest: The payment request to melt for
    ///   - method: Payment method
    ///   - unit: Currency unit
    ///   - availableProofs: Available proofs in wallet
    ///   - mintURL: The base URL of the mint
    ///   - configuration: Fee return configuration
    /// - returns: MeltPreparation with blank outputs for fee return
    public func prepareMeltWithFeeReturn(
        paymentRequest: String,
        method: PaymentMethod,
        unit: String,
        availableProofs: [Proof],
        at mintURL: String,
        configuration: FeeReturnConfiguration? = nil
    ) async throws -> (preparation: MeltPreparation, blankOutputs: [BlankOutput]) {
        // Get initial quote
        let quote = try await requestMeltQuote(
            request: paymentRequest,
            method: method,
            unit: unit,
            at: mintURL
        )
        
        // Calculate blank outputs needed
        let feeReserve = quote.feeReserve ?? 0
        let blankOutputCount = FeeReturnCalculator.calculateBlankOutputCount(feeReserve: feeReserve)
        
        // Use configuration if provided or get active keyset
        let keysetID: String
        if let configuration = configuration {
            keysetID = configuration.keysetID
        } else {
            let activeKeysets = try await keysetManagementService.getActiveKeysets(from: mintURL)
            keysetID = activeKeysets.first?.id ?? ""
        }
        
        // Generate blank outputs
        let blankOutputs = try await BlankOutputGenerator.generateBlankOutputs(
            count: blankOutputCount,
            keysetID: keysetID
        )
        
        // Get keyset information for fee calculation
        let keysetResponse = try await keysetManagementService.getKeysets(from: mintURL)
        let keysetDict = Dictionary(uniqueKeysWithValues: keysetResponse.keysets.map { ($0.id, $0) })
        
        // Select optimal proofs for the required amount (including fee reserve)
        let totalRequired = quote.totalAmountWithFeeReserve
        let selectionResult = try await keysetManagementService.calculateOptimalProofSelection(
            availableProofs: availableProofs,
            targetAmount: totalRequired,
            from: mintURL
        )
        
        guard let selection = selectionResult.recommended else {
            throw CashuError.insufficientFunds
        }
        
        // Calculate fees
        let fees = FeeCalculator.calculateFees(for: selection.selectedProofs, keysetInfo: keysetDict)
        let totalInput = selection.totalAmount
        let requiredAmount = quote.amount + fees + feeReserve
        
        guard totalInput >= requiredAmount else {
            throw CashuError.insufficientFunds
        }
        
        let changeAmount = totalInput - requiredAmount
        
        // Create change outputs if needed (separate from blank outputs)
        var blindedMessages: [BlindedMessage]?
        var blindingData: [WalletBlindingData]?
        
        if changeAmount > 0 {
            // Create optimal denominations for regular change
            let changeAmounts = createOptimalDenominations(for: changeAmount)
            
            // Create blinded messages for change
            var messages: [BlindedMessage] = []
            var blindings: [WalletBlindingData] = []
            
            for amount in changeAmounts {
                let secret = CashuKeyUtils.generateRandomSecret()
                let walletBlindingData = try WalletBlindingData(secret: secret)
                let blindedMessage = BlindedMessage(
                    amount: amount,
                    id: keysetID,
                    B_: walletBlindingData.blindedMessage.dataRepresentation.hexString
                )
                
                messages.append(blindedMessage)
                blindings.append(walletBlindingData)
            }
            
            blindedMessages = messages
            blindingData = blindings
        }
        
        let preparation = MeltPreparation(
            quote: quote,
            inputProofs: selection.selectedProofs,
            blindedMessages: blindedMessages,
            blindingData: blindingData,
            requiredAmount: requiredAmount,
            changeAmount: changeAmount,
            fees: fees
        )
        
        return (preparation, blankOutputs)
    }
    
    /// Execute a melt operation with fee return (NUT-08)
    /// - parameters:
    ///   - preparation: Prepared melt data
    ///   - blankOutputs: Blank outputs for fee return
    ///   - method: Payment method
    ///   - mintURL: The base URL of the mint
    /// - returns: MeltResult with fee return data
    public func executeMeltWithFeeReturn(
        preparation: MeltPreparation,
        blankOutputs: [BlankOutput],
        method: PaymentMethod,
        at mintURL: String
    ) async throws -> (meltResult: MeltResult, feeReturn: FeeReturnResult?) {
        // Create melt request with blank outputs
        let blankOutputMessages = blankOutputs.map { $0.blindedMessage }
        let request = PostMeltRequest(
            quote: preparation.quote.quote,
            inputs: preparation.inputProofs,
            outputs: blankOutputMessages
        )
        
        // Execute melt
        let response = try await executeMelt(request, method: method, at: mintURL)
        
        // Validate response
        guard response.validate() else {
            throw CashuError.invalidResponse
        }
        
        // Process regular change first
        var changeProofs: [Proof] = []
        
        if let changeSignatures = response.change,
           let _ = preparation.blindedMessages,
           let blindingData = preparation.blindingData {
            
            // Get mint public keys for unblinding
            let keyResponse = try await keyExchangeService.getKeys(from: mintURL)
            let mintKeys = Dictionary(uniqueKeysWithValues: keyResponse.keysets.flatMap { keyset in
                keyset.keys.compactMap { (amountStr, publicKeyHex) -> (String, P256K.KeyAgreement.PublicKey)? in
                    guard let amount = Int(amountStr),
                          let publicKeyData = Data(hexString: publicKeyHex),
                          let publicKey = try? P256K.KeyAgreement.PublicKey(dataRepresentation: publicKeyData, format: .compressed) else {
                        return nil
                    }
                    return ("\(keyset.id)_\(amount)", publicKey)
                }
            })
            
            // Unblind signatures to create change proofs
            for (index, signature) in changeSignatures.enumerated() {
                let blindingDataItem = blindingData[index]
                let mintKeyKey = "\(signature.id)_\(signature.amount)"
                
                guard let mintPublicKey = mintKeys[mintKeyKey] else {
                    throw CashuError.invalidSignature("Mint public key not found for amount \(signature.amount)")
                }
                
                guard let blindedSignatureData = Data(hexString: signature.C_) else {
                    throw CashuError.invalidHexString
                }
                
                let unblindedToken = try Wallet.unblindSignature(
                    blindedSignature: blindedSignatureData,
                    blindingData: blindingDataItem,
                    mintPublicKey: mintPublicKey
                )
                
                let proof = Proof(
                    amount: signature.amount,
                    id: signature.id,
                    secret: unblindedToken.secret,
                    C: unblindedToken.signature.hexString
                )
                
                changeProofs.append(proof)
            }
        }
        
        // Process fee return if any change signatures were returned
        var feeReturnResult: FeeReturnResult?
        
        if response.hasFeesReturned && !blankOutputs.isEmpty {
            // Get mint public keys for unblinding fee returns
            let keyResponse = try await keyExchangeService.getKeys(from: mintURL)
            let mintPublicKeyData = Dictionary(uniqueKeysWithValues: keyResponse.keysets.flatMap { keyset in
                keyset.keys.compactMap { (amountStr, publicKeyHex) -> (String, Data)? in
                    guard let amount = Int(amountStr),
                          let publicKeyData = Data(hexString: publicKeyHex) else {
                        return nil
                    }
                    return ("\(amount)", publicKeyData)
                }
            })
            
            // Process fee return signatures
            feeReturnResult = try BlankOutputGenerator.processChangeSignatures(
                changeSignatures: response.change ?? [],
                blankOutputs: blankOutputs,
                mintPublicKeys: mintPublicKeyData
            )
            
            // Add fee return proofs to change proofs
            if let feeReturn = feeReturnResult {
                changeProofs.append(contentsOf: feeReturn.returnedProofs)
            }
        }
        
        let meltResult = MeltResult(
            state: response.state,
            changeProofs: changeProofs,
            spentProofs: preparation.inputProofs,
            meltType: .payment,
            totalAmount: preparation.inputProofs.reduce(0) { $0 + $1.amount },
            fees: preparation.fees,
            paymentProof: nil
        )
        
        return (meltResult, feeReturnResult)
    }
    
    /// Complete melt operation with fee return (prepare + execute)
    /// - parameters:
    ///   - paymentRequest: The payment request to melt for
    ///   - method: Payment method
    ///   - unit: Currency unit
    ///   - availableProofs: Available proofs in wallet
    ///   - mintURL: The base URL of the mint
    ///   - configuration: Fee return configuration
    /// - returns: MeltResult and FeeReturnResult
    public func meltToPaymentWithFeeReturn(
        paymentRequest: String,
        method: PaymentMethod,
        unit: String,
        from availableProofs: [Proof],
        at mintURL: String,
        configuration: FeeReturnConfiguration? = nil
    ) async throws -> (meltResult: MeltResult, feeReturn: FeeReturnResult?) {
        let (preparation, blankOutputs) = try await prepareMeltWithFeeReturn(
            paymentRequest: paymentRequest,
            method: method,
            unit: unit,
            availableProofs: availableProofs,
            at: mintURL,
            configuration: configuration
        )
        
        return try await executeMeltWithFeeReturn(
            preparation: preparation,
            blankOutputs: blankOutputs,
            method: method,
            at: mintURL
        )
    }
    
    // MARK: - Utility Methods
    
    /// Create optimal denominations for an amount (powers of 2)
    private func createOptimalDenominations(for amount: Int) -> [Int] {
        var denominations: [Int] = []
        var remaining = amount
        var power = 0
        
        while remaining > 0 {
            let denomination = 1 << power // 2^power
            if remaining & denomination != 0 {
                denominations.append(denomination)
                remaining -= denomination
            }
            power += 1
        }
        
        return denominations.sorted() // Privacy-preserving order
    }
    
    // Removed local normalizeMintURL in favor of ValidationUtils.normalizeMintURL
    
    // MARK: - Validation Methods
    
    /// Validate melt quote against available proofs
    public nonisolated func validateMeltQuote(
        _ quote: PostMeltQuoteResponse,
        against availableProofs: [Proof],
        keysetInfo: [String: KeysetInfo]
    ) -> Bool {
        let totalAvailable = availableProofs.reduce(0) { $0 + $1.amount }
        let fees = FeeCalculator.calculateFees(for: availableProofs, keysetInfo: keysetInfo)
        let requiredAmount = quote.amount + fees
        
        return totalAvailable >= requiredAmount && !quote.isExpired
    }
    
    /// Check if a payment method is supported for a unit
    public func isMethodSupported(
        _ method: PaymentMethod,
        for unit: String,
        at mintURL: String
    ) async throws -> Bool {
        // This would typically come from NUT-06 mint info
        // For now, assume basic support
        return true
    }
}

// MARK: - API Endpoints

enum MeltAPI {
    case requestMeltQuote(String, PostMeltQuoteRequest)
    case requestMeltQuoteWithMPP(String, PostMeltQuoteBolt11Request)  // NUT-15 support
    case checkMeltQuote(String, String)
    case executeMelt(String, PostMeltRequest)
}

extension MeltAPI: EndpointType {
    public var baseURL: URL {
        guard let baseURL = CashuEnvironment.current.baseURL,
              let url = URL(string: baseURL) else {
            fatalError("The baseURL for the mint must be set")
        }
        return url
    }
    
    var path: String {
        switch self {
        case .requestMeltQuote(let method, _), .requestMeltQuoteWithMPP(let method, _):
            return "/v1/melt/quote/\(method)"
        case .checkMeltQuote(let method, let quoteID):
            return "/v1/melt/quote/\(method)/\(quoteID)"
        case .executeMelt(let method, _):
            return "/v1/melt/\(method)"
        }
    }
    
    var httpMethod: HTTPMethod {
        switch self {
        case .requestMeltQuote, .requestMeltQuoteWithMPP, .executeMelt:
            return .post
        case .checkMeltQuote:
            return .get
        }
    }
    
    var task: HTTPTask {
        switch self {
        case .requestMeltQuote(_, let request):
            return .requestParameters(encoding: .jsonEncodableEncoding(encodable: request))
        case .requestMeltQuoteWithMPP(_, let request):
            return .requestParameters(encoding: .jsonEncodableEncoding(encodable: request))
        case .checkMeltQuote:
            return .request
        case .executeMelt(_, let request):
            return .requestParameters(encoding: .jsonEncodableEncoding(encodable: request))
        }
    }
    
    var headers: HTTPHeaders? {
        return [
            "Accept": "application/json",
            "Content-Type": "application/json"
        ]
    }
}

// MARK: - Convenience Extensions

/// Extension for easier melt operations
extension MeltService {
    /// Check if a quote is ready for payment
    public func isQuoteReady(
        quoteID: String,
        method: PaymentMethod,
        at mintURL: String
    ) async throws -> Bool {
        let quote = try await checkMeltQuote(quoteID: quoteID, method: method, at: mintURL)
        return quote.state.canPay && !quote.isExpired
    }
    
    /// Wait for a quote to be paid (polling)
    public func waitForQuotePayment(
        quoteID: String,
        method: PaymentMethod,
        at mintURL: String,
        timeout: TimeInterval = 300.0,
        pollInterval: TimeInterval = 2.0
    ) async throws -> PostMeltQuoteResponse {
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < timeout {
            let quote = try await checkMeltQuote(quoteID: quoteID, method: method, at: mintURL)
            
            if quote.state.isFinal {
                return quote
            }
            
            if quote.isExpired {
                throw CashuError.validationFailed
            }
            
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        
        throw CashuError.networkError("Timeout waiting for quote payment")
    }
}
