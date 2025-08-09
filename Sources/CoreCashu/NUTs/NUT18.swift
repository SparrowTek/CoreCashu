//
//  NUT18.swift
//  CashuKit
//
//  NUT-18: Payment Requests
//  https://github.com/cashubtc/nuts/blob/main/18.md
//

import Foundation
import SwiftCBOR
import P256K

// MARK: - NUT-18: Payment Requests

/// NUT-18: Payment Requests
/// This NUT introduces a standardised format for payment requests that supply a sending wallet 
/// with all information necessary to complete the transaction

// MARK: - Payment Request

/// Payment Request structure
public struct PaymentRequest: CashuCodabale, Sendable {
    /// Payment id to be included in the payment payload
    public let i: String?
    
    /// The amount of the requested payment
    public let a: Int?
    
    /// The unit of the requested payment (MUST be set if `a` is set)
    public let u: String?
    
    /// Whether the payment request is for single use
    public let s: Bool?
    
    /// A set of mints from which the payment is requested
    public let m: [String]?
    
    /// A human readable description that the sending wallet will display after scanning the request
    public let d: String?
    
    /// The method of Transport chosen to transmit the payment (can be multiple, sorted by preference)
    public let t: [Transport]?
    
    /// The required NUT-10 locking condition
    public let nut10: NUT10Option?
    
    public init(
        i: String? = nil,
        a: Int? = nil,
        u: String? = nil,
        s: Bool? = nil,
        m: [String]? = nil,
        d: String? = nil,
        t: [Transport]? = nil,
        nut10: NUT10Option? = nil
    ) {
        self.i = i
        self.a = a
        self.u = u
        self.s = s
        self.m = m
        self.d = d
        self.t = t
        self.nut10 = nut10
    }
    
    /// Validate the payment request
    public func validate() throws {
        // If amount is set, unit must be set
        if a != nil && u == nil {
            throw CashuError.invalidPaymentRequest("Amount is set but unit is missing")
        }
        
        // Amount must be positive if set
        if let amount = a, amount <= 0 {
            throw CashuError.invalidPaymentRequest("Amount must be positive")
        }
        
        // Validate mints are valid URLs
        if let mints = m {
            for mint in mints {
                guard let url = URL(string: mint), url.scheme != nil else {
                    throw CashuError.invalidPaymentRequest("Invalid mint URL: \(mint)")
                }
            }
        }
        
        // Validate transport targets
        if let transports = t {
            for transport in transports {
                try transport.validate()
            }
        }
    }
    
    /// Check if payment request is for single use
    public var isSingleUse: Bool {
        return s ?? false
    }
    
    /// Get the payment amount
    public var amount: Int? {
        return a
    }
    
    /// Get the payment unit
    public var unit: String? {
        return u
    }
    
    /// Get the payment id
    public var paymentId: String? {
        return i
    }
    
    /// Get the description
    public var description: String? {
        return d
    }
    
    /// Get the mints
    public var mints: [String]? {
        return m
    }
    
    /// Get the transports
    public var transports: [Transport]? {
        return t
    }
    
    /// Get the NUT-10 locking condition
    public var lockingCondition: NUT10Option? {
        return nut10
    }
}

// MARK: - Transport

/// Transport methods for sending ecash to the receiver
public struct Transport: CashuCodabale, Sendable {
    /// Type of Transport
    public let t: String
    
    /// Target of Transport
    public let a: String
    
    /// Optional tags for the Transport
    public let g: [[String]]?
    
    public init(t: String, a: String, g: [[String]]? = nil) {
        self.t = t
        self.a = a
        self.g = g
    }
    
    /// Validate the transport
    public func validate() throws {
        switch t {
        case "nostr":
            try validateNostrTransport()
        case "post":
            try validatePostTransport()
        default:
            // Unknown transport types are allowed for future extensibility
            break
        }
    }
    
    private func validateNostrTransport() throws {
        // Validate nprofile format
        guard a.hasPrefix("nprofile1") else {
            throw CashuError.invalidPaymentRequest("Invalid nostr nprofile format")
        }
        
        // Validate required NIP tags
        if let tags = g {
            let nTags = tags.filter { $0.first == "n" }
            guard !nTags.isEmpty else {
                throw CashuError.invalidPaymentRequest("Nostr transport requires 'n' tag specifying supported NIPs")
            }
        }
    }
    
    private func validatePostTransport() throws {
        // Validate URL format
        guard let url = URL(string: a), url.scheme != nil else {
            throw CashuError.invalidPaymentRequest("Invalid POST endpoint URL")
        }
    }
    
    /// Get transport type
    public var type: TransportType {
        return TransportType(rawValue: t) ?? .unknown
    }
    
    /// Get transport target
    public var target: String {
        return a
    }
    
    /// Get transport tags
    public var tags: [[String]]? {
        return g
    }
}

/// Transport types
public enum TransportType: String, CaseIterable, Sendable {
    case nostr = "nostr"
    case post = "post"
    case unknown = "unknown"
    
    public var description: String {
        switch self {
        case .nostr:
            return "Nostr Direct Message"
        case .post:
            return "HTTP POST"
        case .unknown:
            return "Unknown Transport"
        }
    }
}

// MARK: - NUT-10 Option

/// NUT-10 locking condition option for payment requests
public struct NUT10Option: CashuCodabale, Sendable {
    /// The kind of locking condition
    public let kind: String
    
    /// The data for the locking condition
    public let data: String
    
    /// Optional tags for the locking condition
    public let tags: [[String]]?
    
    public init(kind: String, data: String, tags: [[String]]? = nil) {
        self.kind = kind
        self.data = data
        self.tags = tags
    }
    
    /// Get the locking condition type
    public var lockingType: LockingConditionType {
        return LockingConditionType(rawValue: kind) ?? .unknown
    }
}

/// Locking condition types
public enum LockingConditionType: String, CaseIterable, Sendable {
    case p2pk = "P2PK"
    case htlc = "HTLC"
    case unknown = "unknown"
    
    public var description: String {
        switch self {
        case .p2pk:
            return "Pay to Public Key"
        case .htlc:
            return "Hash Time Lock Contract"
        case .unknown:
            return "Unknown Locking Condition"
        }
    }
}

// MARK: - Payment Payload

/// Payment payload sent to the receiver
public struct PaymentRequestPayload: CashuCodabale, Sendable {
    /// Payment id (corresponding to `i` in request)
    public let id: String?
    
    /// Optional memo to be sent to the receiver with the payment
    public let memo: String?
    
    /// Mint URL from which the ecash is from
    public let mint: String
    
    /// Unit of the payment
    public let unit: String
    
    /// Array of proofs (can include DLEQ proofs)
    public let proofs: [Proof]
    
    public init(
        id: String? = nil,
        memo: String? = nil,
        mint: String,
        unit: String,
        proofs: [Proof]
    ) {
        self.id = id
        self.memo = memo
        self.mint = mint
        self.unit = unit
        self.proofs = proofs
    }
    
    /// Calculate total amount of the payment
    public var totalAmount: Int {
        return proofs.reduce(0) { $0 + $1.amount }
    }
    
    /// Validate the payment payload
    public func validate() throws {
        // Validate mint URL
        guard let url = URL(string: mint), url.scheme != nil else {
            throw CashuError.invalidPaymentRequest("Invalid mint URL")
        }
        
        // Validate unit
        guard !unit.isEmpty else {
            throw CashuError.invalidPaymentRequest("Unit cannot be empty")
        }
        
        // Validate proofs
        guard !proofs.isEmpty else {
            throw CashuError.invalidPaymentRequest("Proofs cannot be empty")
        }
        
        // Validate each proof
        for proof in proofs {
            guard proof.amount > 0 else {
                throw CashuError.invalidPaymentRequest("Proof amount must be positive")
            }
        }
    }
    
    /// Check if payment matches the request
    public func matches(_ request: PaymentRequest) -> Bool {
        // Check payment id
        if let requestId = request.paymentId, id != requestId {
            return false
        }
        
        // Check amount
        if let requestAmount = request.amount, totalAmount != requestAmount {
            return false
        }
        
        // Check unit
        if let requestUnit = request.unit, unit != requestUnit {
            return false
        }
        
        // Check mint
        if let requestMints = request.mints, !requestMints.contains(mint) {
            return false
        }
        
        return true
    }
}

// MARK: - Payment Request Encoding/Decoding

/// Payment request encoder/decoder
public struct PaymentRequestEncoder: Sendable {
    /// Encode a payment request to the standard format
    /// Format: "creq" + "A" + base64_urlsafe(CBOR(PaymentRequest))
    public static func encode(_ request: PaymentRequest) throws -> String {
        // First validate the request
        try request.validate()
        
        // Convert to CBOR
        let cborData = try encodeToCBOR(request)
        
        // Encode to base64 URL-safe
        let base64String = cborData.base64URLSafeEncodedString()
        
        // Add prefix and version
        return "creq" + "A" + base64String
    }
    
    /// Decode a payment request from the standard format
    public static func decode(_ encoded: String) throws -> PaymentRequest {
        // Check prefix
        guard encoded.hasPrefix("creqA") else {
            throw CashuError.invalidPaymentRequest("Invalid payment request format")
        }
        
        // Remove prefix and version
        let base64String = String(encoded.dropFirst(5))
        
        // Decode from base64 URL-safe
        guard let cborData = Data(base64URLSafeEncoded: base64String) else {
            throw CashuError.invalidPaymentRequest("Invalid base64 encoding")
        }
        
        // Decode from CBOR
        let request: PaymentRequest = try decodeFromCBOR(cborData, type: PaymentRequest.self)
        
        // Validate the decoded request
        try request.validate()
        
        return request
    }
    
}

// MARK: - Payment Request Builder

/// Builder for creating payment requests
public struct PaymentRequestBuilder: Sendable {
    private var paymentId: String?
    private var amount: Int?
    private var unit: String?
    private var singleUse: Bool?
    private var mints: [String]?
    private var description: String?
    private var transports: [Transport]?
    private var lockingCondition: NUT10Option?
    
    public init() {}
    
    /// Set payment id
    public func withPaymentId(_ id: String) -> PaymentRequestBuilder {
        var builder = self
        builder.paymentId = id
        return builder
    }
    
    /// Set amount and unit
    public func withAmount(_ amount: Int, unit: String) -> PaymentRequestBuilder {
        var builder = self
        builder.amount = amount
        builder.unit = unit
        return builder
    }
    
    /// Set single use flag
    public func withSingleUse(_ singleUse: Bool) -> PaymentRequestBuilder {
        var builder = self
        builder.singleUse = singleUse
        return builder
    }
    
    /// Set mints
    public func withMints(_ mints: [String]) -> PaymentRequestBuilder {
        var builder = self
        builder.mints = mints
        return builder
    }
    
    /// Set description
    public func withDescription(_ description: String) -> PaymentRequestBuilder {
        var builder = self
        builder.description = description
        return builder
    }
    
    /// Add transport
    public func withTransport(_ transport: Transport) -> PaymentRequestBuilder {
        var builder = self
        if builder.transports == nil {
            builder.transports = []
        }
        builder.transports?.append(transport)
        return builder
    }
    
    /// Add Nostr transport
    public func withNostrTransport(nprofile: String, nips: [String]) -> PaymentRequestBuilder {
        let tags = nips.map { ["n", $0] }
        let transport = Transport(t: "nostr", a: nprofile, g: tags)
        return withTransport(transport)
    }
    
    /// Add HTTP POST transport
    public func withPostTransport(url: String) -> PaymentRequestBuilder {
        let transport = Transport(t: "post", a: url)
        return withTransport(transport)
    }
    
    /// Set locking condition
    public func withLockingCondition(_ condition: NUT10Option) -> PaymentRequestBuilder {
        var builder = self
        builder.lockingCondition = condition
        return builder
    }
    
    /// Build the payment request
    public func build() throws -> PaymentRequest {
        let request = PaymentRequest(
            i: paymentId,
            a: amount,
            u: unit,
            s: singleUse,
            m: mints,
            d: description,
            t: transports,
            nut10: lockingCondition
        )
        
        try request.validate()
        return request
    }
}

// MARK: - Payment Request Processor

/// Processor for handling payment requests
public struct PaymentRequestProcessor: Sendable {
    /// Process a payment request and create a payment payload
    public static func processPaymentRequest(
        _ request: PaymentRequest,
        wallet: CashuWallet,
        memo: String? = nil
    ) async throws -> PaymentRequestPayload {
        // Validate request
        try request.validate()
        
        // Check if we have the required amount
        guard let requestAmount = request.amount else {
            throw CashuError.invalidPaymentRequest("Payment request must specify amount")
        }
        
        guard let requestUnit = request.unit else {
            throw CashuError.invalidPaymentRequest("Payment request must specify unit")
        }
        
        // Check if we have sufficient balance
        let balanceBreakdown = try await wallet.getBalanceBreakdown()
        guard balanceBreakdown.totalBalance >= requestAmount else {
            throw CashuError.insufficientFunds
        }
        
        // Select appropriate mint
        let mintURL = await wallet.mintURL
        if let requestMints = request.mints {
            guard requestMints.contains(mintURL) else {
                throw CashuError.invalidPaymentRequest("Wallet mint not in requested mints")
            }
        }
        
        // Create payment proofs
        let proofs = try await selectProofsForPayment(
            amount: requestAmount,
            wallet: wallet,
            lockingCondition: request.lockingCondition
        )
        
        // Create payment payload
        let payload = PaymentRequestPayload(
            id: request.paymentId,
            memo: memo,
            mint: mintURL,
            unit: requestUnit,
            proofs: proofs
        )
        
        try payload.validate()
        return payload
    }
    
    /// Select proofs for payment with optional locking condition
    private static func selectProofsForPayment(
        amount: Int,
        wallet: CashuWallet,
        lockingCondition: NUT10Option?
    ) async throws -> [Proof] {
        // Get available proofs from the wallet
        let balanceBreakdown = try await wallet.getBalanceBreakdown()
        guard balanceBreakdown.totalBalance >= amount else {
            throw CashuError.insufficientFunds
        }
        
        // Use the wallet's internal proof selection
        // The wallet has access to proofManager privately
        let selectedProofs = try await wallet.selectProofsForAmount(amount)
        
        // If we have a locking condition, we need to create new locked proofs
        if let lockingCondition = lockingCondition {
            // Create a swap to convert selected proofs to locked proofs
            return try await createLockedProofs(
                from: selectedProofs,
                lockingCondition: lockingCondition,
                wallet: wallet
            )
        }
        
        return selectedProofs
    }
    
    /// Create locked proofs from regular proofs using a swap operation
    private static func createLockedProofs(
        from proofs: [Proof],
        lockingCondition: NUT10Option,
        wallet: CashuWallet
    ) async throws -> [Proof] {
        // Validate the locking condition type
        guard lockingCondition.lockingType == .p2pk else {
            throw CashuError.unsupportedOperation("Only P2PK locking conditions are currently supported")
        }
        
        // Extract the public key from the locking condition data
        guard !lockingCondition.data.isEmpty else {
            throw CashuError.invalidProof
        }
        
        // Create a P2PK spending condition
        let spendingCondition = P2PKSpendingCondition.simple(publicKey: lockingCondition.data)
        let wellKnownSecret = spendingCondition.toWellKnownSecret()
        
        // Get the swap service from the wallet
        guard let swapService = await wallet.getSwapService() else {
            throw CashuError.notImplemented
        }
        
        // Get wallet mint URL
        let walletMintURL = await wallet.mintURL
        
        // Calculate total amount from proofs
        let totalAmount = proofs.reduce(0) { $0 + $1.amount }
        
        // Create optimal denominations for the locked proofs
        let outputAmounts = createOptimalDenominations(for: totalAmount)
        
        // Prepare the swap with locked outputs
        var lockedBlindedMessages: [BlindedMessage] = []
        var blindingDataMap: [String: WalletBlindingData] = [:]
        
        // Get active keyset
        let activeKeysets = try await wallet.getActiveKeysets()
        let walletUnit = await wallet.unit
        guard let activeKeyset = activeKeysets.first(where: { $0.unit == walletUnit }) else {
            throw CashuError.keysetInactive
        }
        
        // Use the well-known secret as the secret for locked proofs
        let secretString = try wellKnownSecret.toJSONString()
        
        for amount in outputAmounts {
            let blindingData = try WalletBlindingData(secret: secretString)
            
            let blindedMessage = BlindedMessage(
                amount: amount,
                id: activeKeyset.id,
                B_: blindingData.blindedMessage.dataRepresentation.hexString
            )
            
            lockedBlindedMessages.append(blindedMessage)
            blindingDataMap[blindedMessage.B_] = blindingData
        }
        
        // Create swap request
        let swapRequest = PostSwapRequest(
            inputs: proofs,
            outputs: lockedBlindedMessages
        )
        
        // Execute the swap
        let swapResponse = try await swapService.executeSwap(
            swapRequest,
            at: walletMintURL
        )
        
        // Validate response
        guard swapResponse.signatures.count == lockedBlindedMessages.count else {
            throw CashuError.invalidResponse
        }
        
        // Unblind the signatures to create locked proofs
        var lockedProofs: [Proof] = []
        
        // Get key exchange service to fetch mint keys
        guard let keyExchangeService = await wallet.getKeyExchangeService() else {
            throw CashuError.notImplemented
        }
        
        let keyResponse = try await keyExchangeService.getKeys(from: walletMintURL)
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
        
        for (index, signature) in swapResponse.signatures.enumerated() {
            let blindedMessage = lockedBlindedMessages[index]
            guard let blindingData = blindingDataMap[blindedMessage.B_] else {
                throw CashuError.missingBlindingFactor
            }
            
            let mintKeyKey = "\(signature.id)_\(signature.amount)"
            guard let mintPublicKey = mintKeys[mintKeyKey] else {
                throw CashuError.invalidSignature("Mint public key not found for amount \(signature.amount)")
            }
            
            guard let blindedSignatureData = Data(hexString: signature.C_) else {
                throw CashuError.invalidHexString
            }
            
            let unblindedToken = try Wallet.unblindSignature(
                blindedSignature: blindedSignatureData,
                blindingData: blindingData,
                mintPublicKey: mintPublicKey
            )
            
            // Create locked proof with the well-known secret
            let lockedProof = Proof(
                amount: signature.amount,
                id: signature.id,
                secret: secretString,
                C: unblindedToken.signature.hexString
            )
            
            lockedProofs.append(lockedProof)
        }
        
        return lockedProofs
    }
    
    /// Create optimal denominations for an amount (powers of 2)
    private static func createOptimalDenominations(for amount: Int) -> [Int] {
        var denominations: [Int] = []
        var remaining = amount
        var power = 0
        
        while remaining > 0 {
            let denomination = 1 << power
            if remaining & denomination != 0 {
                denominations.append(denomination)
                remaining -= denomination
            }
            power += 1
        }
        
        return denominations.sorted()
    }
}

// MARK: - Extensions

extension Data {
    /// Base64 URL-safe encoding
    func base64URLSafeEncodedString() -> String {
        let base64 = self.base64EncodedString()
        return base64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    
    /// Base64 URL-safe decoding
    init?(base64URLSafeEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        
        // Add padding if needed
        let padding = 4 - (base64.count % 4)
        if padding != 4 {
            base64 += String(repeating: "=", count: padding)
        }
        
        guard let data = Data(base64Encoded: base64) else {
            return nil
        }
        
        self = data
    }
}

// MARK: - Error Extensions

extension CashuError {
    /// Invalid payment request error
    public static func invalidPaymentRequest(_ message: String) -> CashuError {
        return .networkError("Invalid payment request: \(message)")
    }
    
    /// Not implemented error
    public static func notImplemented(_ message: String) -> CashuError {
        return .unsupportedOperation("Not implemented: \(message)")
    }
}