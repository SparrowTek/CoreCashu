//
//  NUT03.swift
//  CashuKit
//
//  NUT-03: Swap tokens
//  https://github.com/cashubtc/nuts/blob/main/03.md
//

import Foundation
@preconcurrency import P256K

// MARK: - NUT-03: Swap tokens

/// NUT-03: Swap tokens
/// This NUT defines the swap operation for splitting and combining tokens

// MARK: - Request/Response Structures

/// Request structure for POST /v1/swap
public struct PostSwapRequest: CashuCodabale {
    public let inputs: [Proof]
    public let outputs: [BlindedMessage]
    
    public init(inputs: [Proof], outputs: [BlindedMessage]) {
        self.inputs = inputs
        self.outputs = outputs
    }
    
    /// Validate the swap request structure
    public func validate() -> Bool {
        // Must have inputs and outputs
        guard !inputs.isEmpty, !outputs.isEmpty else { return false }
        
        // Basic validation for inputs
        for input in inputs {
            guard input.amount > 0,
                  !input.id.isEmpty,
                  !input.secret.isEmpty,
                  !input.C.isEmpty else {
                return false
            }
        }
        
        // Basic validation for outputs
        for output in outputs {
            guard output.amount > 0,
                  let outputId = output.id, !outputId.isEmpty,
                  !output.B_.isEmpty else {
                return false
            }
        }
        
        // If any input has a witness, validate it exists for corresponding outputs
        for input in inputs {
            if input.witness != nil {
                // Witness validation is handled by the mint
                continue
            }
        }
        
        return true
    }
    
    /// Get total input amount
    public var totalInputAmount: Int {
        return inputs.reduce(0) { $0 + $1.amount }
    }
    
    /// Get total output amount
    public var totalOutputAmount: Int {
        return outputs.reduce(0) { $0 + $1.amount }
    }
    
    /// Check if outputs are privacy-preserving (ordered by amount ascending)
    public var hasPrivacyPreservingOrder: Bool {
        let amounts = outputs.map { $0.amount }
        return amounts == amounts.sorted()
    }
}

/// Response structure for POST /v1/swap
public struct PostSwapResponse: CashuCodabale {
    public let signatures: [BlindSignature]
    
    public init(signatures: [BlindSignature]) {
        self.signatures = signatures
    }
    
    /// Validate the swap response structure
    public func validate() -> Bool {
        guard !signatures.isEmpty else { return false }
        
        for signature in signatures {
            guard signature.amount > 0,
                  !signature.id.isEmpty,
                  !signature.C_.isEmpty else {
                return false
            }
        }
        
        return true
    }
    
    /// Get total signature amount
    public var totalAmount: Int {
        return signatures.reduce(0) { $0 + $1.amount }
    }
}

// MARK: - Swap Operation Types

/// Type of swap operation
public enum SwapType: String, CaseIterable, Sendable {
    case send = "send"           // Swap to prepare tokens for sending
    case receive = "receive"     // Swap to receive and invalidate tokens
    case split = "split"         // Swap to split large denominations
    case combine = "combine"     // Swap to combine small denominations
    case rotate = "rotate"       // Swap from inactive to active keysets
}

/// Swap operation result
public struct SwapResult: Sendable {
    public let newProofs: [Proof]
    public let invalidatedProofs: [Proof]
    public let swapType: SwapType
    public let totalAmount: Int
    public let fees: Int
    
    public init(newProofs: [Proof], invalidatedProofs: [Proof], swapType: SwapType, totalAmount: Int, fees: Int) {
        self.newProofs = newProofs
        self.invalidatedProofs = invalidatedProofs
        self.swapType = swapType
        self.totalAmount = totalAmount
        self.fees = fees
    }
}

/// Swap preparation result
public struct SwapPreparation: Sendable {
    public let inputProofs: [Proof]
    public let blindedMessages: [BlindedMessage]
    public let blindingData: [WalletBlindingData]
    public let targetAmount: Int?
    public let targetOutputDenominations: [Int]
    public let changeAmount: Int
    public let fees: Int
    /// Set of `proof.secret` strings that the wallet flagged as "target" outputs (i.e., the
    /// proofs being sent, as opposed to change). Empty when no locking is requested. Used by
    /// `partitionSwapOutputs` to identify target proofs by secret rather than by denomination
    /// — necessary when target and change share denominations and outputs are sorted for
    /// privacy.
    public let targetSecrets: Set<String>

    public init(
        inputProofs: [Proof],
        blindedMessages: [BlindedMessage],
        blindingData: [WalletBlindingData],
        targetAmount: Int?,
        targetOutputDenominations: [Int] = [],
        changeAmount: Int,
        fees: Int,
        targetSecrets: Set<String> = []
    ) {
        self.inputProofs = inputProofs
        self.blindedMessages = blindedMessages
        self.blindingData = blindingData
        self.targetAmount = targetAmount
        self.targetOutputDenominations = targetOutputDenominations
        self.changeAmount = changeAmount
        self.fees = fees
        self.targetSecrets = targetSecrets
    }
}

// MARK: - Swap Service

@CashuActor
public struct SwapService: Sendable {
    private let router: NetworkRouter<SwapAPI>
    private let keyExchangeService: KeyExchangeService
    private let keysetManagementService: KeysetManagementService
    
    public init(networking: (any Networking)? = nil) async {
        self.router = NetworkRouter<SwapAPI>(networking: networking, decoder: .cashuDecoder)
        self.router.delegate = CashuEnvironment.current.routerDelegate
        self.keyExchangeService = await KeyExchangeService(networking: networking)
        self.keysetManagementService = await KeysetManagementService(networking: networking)
    }
    
    /// Execute a swap operation
    /// - parameters:
    ///   - request: The swap request with inputs and outputs
    ///   - mintURL: The base URL of the mint
    ///   - accessToken: Optional access token for NUT-22 authentication
    /// - returns: PostSwapResponse with blind signatures
    public func executeSwap(_ request: PostSwapRequest, at mintURL: String, accessToken: AccessToken? = nil) async throws -> PostSwapResponse {
        // Enhanced validation using NUTValidation
        let validation = NUTValidation.validateSwapRequest(request)
        guard validation.isValid else {
            throw CashuError.validationFailed
        }
        
        // Setup networking
        let normalizedURL = try ValidationUtils.normalizeMintURL(mintURL)
        guard let baseURL = URL(string: normalizedURL) else {
            throw CashuError.invalidMintURL
        }
        
        // Execute swap - use NUT22 request if access token is provided
        if let accessToken = accessToken {
            let nut22Request = NUT22SwapRequest(
                inputs: request.inputs,
                outputs: request.outputs,
                accessToken: accessToken
            )
            return try await router.execute(.swapWithAccessToken(nut22Request, baseURL: baseURL))
        } else {
            return try await router.execute(.swap(request, baseURL: baseURL))
        }
    }
    
    /// Prepare a swap to send tokens (split for target amount)
    /// - parameters:
    ///   - availableProofs: Available proofs in wallet
    ///   - targetAmount: Amount to prepare for sending
    ///   - unit: Currency unit for the swap (optional, inferred from proofs if not provided)
    ///   - mintURL: The base URL of the mint
    ///   - targetSecretFactory: Optional. Called once per *target* output (i.e., the proofs
    ///     being sent, not change) to produce that proof's `secret` string. The factory is
    ///     responsible for embedding any per-output randomness (e.g., a fresh NUT-10 nonce).
    ///     When `nil`, target outputs use random secrets like change outputs (the
    ///     anyone-can-spend default).
    /// - returns: SwapPreparation with prepared inputs and outputs
    public func prepareSwapToSend(
        availableProofs: [Proof],
        targetAmount: Int,
        unit: String? = nil,
        at mintURL: String,
        targetSecretFactory: (@Sendable () throws -> String)? = nil,
        deterministicOutputs: DeterministicOutputProvider? = nil
    ) async throws -> SwapPreparation {
        // Get keyset information for fee calculation
        let keysetResponse = try await keysetManagementService.getKeysets(from: mintURL)
        let keysetDict = Dictionary(uniqueKeysWithValues: keysetResponse.keysets.map { ($0.id, $0) })
        
        // Select optimal proofs for the target amount
        let selectionResult = try await keysetManagementService.calculateOptimalProofSelection(
            availableProofs: availableProofs,
            targetAmount: targetAmount,
            from: mintURL
        )
        
        guard let selection = selectionResult.recommended else {
            throw CashuError.insufficientFunds
        }
        
        // Calculate fees
        let fees = FeeCalculator.calculateFees(for: selection.selectedProofs, keysetInfo: keysetDict)
        let totalInput = selection.totalAmount
        let totalOutput = totalInput - fees
        
        // Create target denominations (optimal split)
        let targetAmountOutputs = createOptimalDenominations(for: targetAmount)
        let changeAmount = totalOutput - targetAmount
        let changeOutputs = changeAmount > 0 ? createOptimalDenominations(for: changeAmount) : []

        // Get active keyset for outputs
        let activeKeysets = try await keysetManagementService.getActiveKeysets(from: mintURL)

        // Infer unit from proofs if not provided
        let targetUnit = unit ?? inferUnitFromProofs(availableProofs, keysetInfo: keysetDict)

        // Filter by unit if available
        let filteredKeysets = if let targetUnit = targetUnit {
            activeKeysets.filter { $0.unit == targetUnit }
        } else {
            activeKeysets
        }

        guard let activeKeyset = filteredKeysets.first else {
            if targetUnit != nil {
                throw CashuError.keysetInactive
            } else {
                throw CashuError.noActiveKeyset
            }
        }

        // Build target outputs (locked or anyone-can-spend depending on factory presence) and
        // change outputs (always anyone-can-spend) separately so the factory is only invoked
        // for target outputs. When `deterministicOutputs` is supplied, anyone-can-spend
        // outputs (i.e., change AND non-locked target outputs) derive their secret + blinding
        // factor from the wallet's seed so `restoreFromSeed` can rediscover them. Locked
        // outputs always use the factory's secret (the secret carries the well-known JSON);
        // their blinding factor is deterministic when a provider is available so the B_ value
        // is reproducible from the seed.
        struct PendingOutput { let amount: Int; let isTarget: Bool; let lockedSecret: String? }
        var pending: [PendingOutput] = []
        var targetSecrets: Set<String> = []

        for amount in targetAmountOutputs {
            if let factory = targetSecretFactory {
                let secret = try factory()
                targetSecrets.insert(secret)
                pending.append(PendingOutput(amount: amount, isTarget: true, lockedSecret: secret))
            } else {
                pending.append(PendingOutput(amount: amount, isTarget: true, lockedSecret: nil))
            }
        }
        for amount in changeOutputs {
            pending.append(PendingOutput(amount: amount, isTarget: false, lockedSecret: nil))
        }

        // Sort by ascending amount for privacy. Stable on equal amounts but ordering between
        // target and change of the same denomination doesn't leak information beyond what the
        // mint already knows (it sees all outputs).
        pending.sort { $0.amount < $1.amount }

        // Reserve a contiguous block of counters up-front so derivation indices are
        // deterministic even after the sort.
        let reservedStart: UInt32?
        if let deterministicOutputs {
            reservedStart = await deterministicOutputs.reserve(count: pending.count, for: activeKeyset.id)
        } else {
            reservedStart = nil
        }

        var blindedMessages: [BlindedMessage] = []
        var blindingData: [WalletBlindingData] = []
        for (index, output) in pending.enumerated() {
            let walletBlindingData: WalletBlindingData
            if let lockedSecret = output.lockedSecret {
                // Locked outputs: secret is the well-known JSON. If we have a deterministic
                // source, use a derived blinding factor so B_ can be reproduced; otherwise
                // random.
                if let deterministicOutputs, let start = reservedStart {
                    let counter = start + UInt32(index)
                    let r = try deterministicOutputs.derivation
                        .deriveBlindingFactor(keysetID: activeKeyset.id, counter: counter)
                    walletBlindingData = try WalletBlindingData(secret: lockedSecret, blindingFactor: r)
                } else {
                    walletBlindingData = try WalletBlindingData(secret: lockedSecret)
                }
            } else if let deterministicOutputs, let start = reservedStart {
                let counter = start + UInt32(index)
                let (secret, r) = try deterministicOutputs.derive(keysetID: activeKeyset.id, counter: counter)
                walletBlindingData = try WalletBlindingData(secret: secret, blindingFactor: r)
            } else {
                let secret = try CashuKeyUtils.generateRandomSecret()
                walletBlindingData = try WalletBlindingData(secret: secret)
            }

            let blindedMessage = BlindedMessage(
                amount: output.amount,
                id: activeKeyset.id,
                B_: walletBlindingData.blindedMessage.dataRepresentation.hexString
            )
            blindedMessages.append(blindedMessage)
            blindingData.append(walletBlindingData)
        }

        return SwapPreparation(
            inputProofs: selection.selectedProofs,
            blindedMessages: blindedMessages,
            blindingData: blindingData,
            targetAmount: targetAmount,
            targetOutputDenominations: targetAmountOutputs,
            changeAmount: changeAmount,
            fees: fees,
            targetSecrets: targetSecrets
        )
    }
    
    /// Prepare a swap to receive tokens (invalidate received tokens)
    /// - parameters:
    ///   - receivedProofs: Proofs received from another user
    ///   - preferredDenominations: Preferred output denominations (optional)
    ///   - unit: Currency unit for the swap (optional, inferred from proofs if not provided)
    ///   - mintURL: The base URL of the mint
    /// - returns: SwapPreparation with prepared inputs and outputs
    public func prepareSwapToReceive(
        receivedProofs: [Proof],
        preferredDenominations: [Int]? = nil,
        unit: String? = nil,
        at mintURL: String,
        deterministicOutputs: DeterministicOutputProvider? = nil
    ) async throws -> SwapPreparation {
        // Get keyset information for fee calculation
        let keysetResponse = try await keysetManagementService.getKeysets(from: mintURL)
        let keysetDict = Dictionary(uniqueKeysWithValues: keysetResponse.keysets.map { ($0.id, $0) })
        
        // Calculate fees
        let fees = FeeCalculator.calculateFees(for: receivedProofs, keysetInfo: keysetDict)
        let totalInput = receivedProofs.reduce(0) { $0 + $1.amount }
        let totalOutput = totalInput - fees
        
        // Create output denominations
        let outputAmounts: [Int]
        if let preferred = preferredDenominations {
            outputAmounts = preferred.sorted() // Privacy-preserving order
        } else {
            outputAmounts = createOptimalDenominations(for: totalOutput)
        }
        
        // Get active keyset for outputs
        let activeKeysets = try await keysetManagementService.getActiveKeysets(from: mintURL)
        
        // Infer unit from proofs if not provided
        let targetUnit = unit ?? inferUnitFromProofs(receivedProofs, keysetInfo: keysetDict)
        
        // Filter by unit if available
        let filteredKeysets = if let targetUnit = targetUnit {
            activeKeysets.filter { $0.unit == targetUnit }
        } else {
            activeKeysets
        }
        
        guard let activeKeyset = filteredKeysets.first else {
            if targetUnit != nil {
                throw CashuError.keysetInactive
            } else {
                throw CashuError.noActiveKeyset
            }
        }
        
        // Create blinded messages. With a deterministic source, derive everything from the
        // wallet's seed so `restoreFromSeed` can rediscover these proofs. Without one (legacy /
        // non-mnemonic wallet), fall back to random secrets like before.
        let blindingData: [WalletBlindingData]
        if let deterministicOutputs {
            blindingData = try await deterministicOutputs.makeBlindingData(
                count: outputAmounts.count,
                for: activeKeyset.id
            )
        } else {
            blindingData = try outputAmounts.map { _ in
                let secret = try CashuKeyUtils.generateRandomSecret()
                return try WalletBlindingData(secret: secret)
            }
        }
        let blindedMessages = zip(outputAmounts, blindingData).map { amount, data in
            BlindedMessage(
                amount: amount,
                id: activeKeyset.id,
                B_: data.blindedMessage.dataRepresentation.hexString
            )
        }
        
        return SwapPreparation(
            inputProofs: receivedProofs,
            blindedMessages: blindedMessages,
            blindingData: blindingData,
            targetAmount: nil,
            targetOutputDenominations: [],
            changeAmount: totalOutput,
            fees: fees
        )
    }
    
    /// Execute a complete swap operation (prepare + execute + unblind)
    /// - parameters:
    ///   - preparation: Prepared swap data
    ///   - mintURL: The base URL of the mint
    /// - returns: SwapResult with new proofs
    public func executeCompleteSwap(
        preparation: SwapPreparation,
        at mintURL: String
    ) async throws -> SwapResult {
        // Create swap request
        let request = PostSwapRequest(
            inputs: preparation.inputProofs,
            outputs: preparation.blindedMessages
        )
        
        // Execute swap
        let response = try await executeSwap(request, at: mintURL)
        
        // Validate response
        guard response.validate(),
              response.signatures.count == preparation.blindingData.count else {
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
        
        // Unblind signatures to create new proofs
        var newProofs: [Proof] = []
        
        for (index, signature) in response.signatures.enumerated() {
            let blindingData = preparation.blindingData[index]
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
            
            let proof = Proof(
                amount: signature.amount,
                id: signature.id,
                secret: unblindedToken.secret,
                C: unblindedToken.signature.hexString
            )
            
            newProofs.append(proof)
        }
        
        // Determine swap type
        let swapType: SwapType
        if preparation.targetAmount != nil {
            swapType = .send
        } else {
            swapType = .receive
        }
        
        return SwapResult(
            newProofs: newProofs,
            invalidatedProofs: preparation.inputProofs,
            swapType: swapType,
            totalAmount: preparation.changeAmount,
            fees: preparation.fees
        )
    }
    
    /// Rotate tokens from inactive keysets to active ones
    /// - parameters:
    ///   - proofs: Proofs to rotate
    ///   - mintURL: The base URL of the mint
    /// - returns: SwapResult with rotated proofs
    public func rotateTokens(proofs: [Proof], at mintURL: String) async throws -> SwapResult {
        // Check which keysets need rotation
        let inactiveKeysetIDs = try await keysetManagementService.getKeysetsNeedingRotation(for: proofs, from: mintURL)
        
        let proofsToRotate = proofs.filter { inactiveKeysetIDs.contains($0.id) }
        guard !proofsToRotate.isEmpty else {
            // No rotation needed
            return SwapResult(
                newProofs: proofs,
                invalidatedProofs: [],
                swapType: .rotate,
                totalAmount: proofs.reduce(0) { $0 + $1.amount },
                fees: 0
            )
        }
        
        // Prepare swap to rotate
        let preparation = try await prepareSwapToReceive(
            receivedProofs: proofsToRotate,
            at: mintURL
        )
        
        // Execute rotation
        let result = try await executeCompleteSwap(preparation: preparation, at: mintURL)
        
        // Combine rotated proofs with non-rotated ones
        let nonRotatedProofs = proofs.filter { !inactiveKeysetIDs.contains($0.id) }
        let allNewProofs = result.newProofs + nonRotatedProofs
        
        return SwapResult(
            newProofs: allNewProofs,
            invalidatedProofs: proofsToRotate,
            swapType: .rotate,
            totalAmount: result.totalAmount,
            fees: result.fees
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
    
    /// Infer unit from proofs using keyset information
    private func inferUnitFromProofs(_ proofs: [Proof], keysetInfo: [String: KeysetInfo]) -> String? {
        // Find the most common unit among the proofs
        var unitCounts: [String: Int] = [:]
        
        for proof in proofs {
            if let keysetInfo = keysetInfo[proof.id] {
                unitCounts[keysetInfo.unit, default: 0] += 1
            }
        }
        
        // Return the most common unit
        return unitCounts.max(by: { $0.value < $1.value })?.key
    }
    
    // Removed local normalizeMintURL in favor of ValidationUtils.normalizeMintURL
    
    // MARK: - Validation Methods
    
    /// Validate swap inputs and outputs balance
    public nonisolated func validateSwapBalance(
        _ request: PostSwapRequest,
        keysetInfo: [String: KeysetInfo]
    ) -> Bool {
        let totalInputs = request.totalInputAmount
        let totalOutputs = request.totalOutputAmount
        let fees = FeeCalculator.calculateFees(for: request.inputs, keysetInfo: keysetInfo)
        
        return totalInputs - fees == totalOutputs
    }
    
    /// Check if all inputs are from active keysets
    public func validateInputsAreFromActiveKeysets(
        inputs: [Proof],
        at mintURL: String
    ) async throws -> Bool {
        let activeKeysets = try await keysetManagementService.getActiveKeysets(from: mintURL)
        let activeKeysetIDs = Set(activeKeysets.map { $0.id })
        
        return inputs.allSatisfy { activeKeysetIDs.contains($0.id) }
    }
    
    /// Check if all outputs target active keysets
    public func validateOutputsTargetActiveKeysets(
        outputs: [BlindedMessage],
        at mintURL: String
    ) async throws -> Bool {
        let activeKeysets = try await keysetManagementService.getActiveKeysets(from: mintURL)
        let activeKeysetIDs = Set(activeKeysets.map { $0.id })
        
        return outputs.allSatisfy { output in
            guard let outputId = output.id else { return false }
            return activeKeysetIDs.contains(outputId)
        }
    }
}

// MARK: - API Endpoints

enum SwapAPI {
    case swap(PostSwapRequest, baseURL: URL)
    case swapWithAccessToken(NUT22SwapRequest, baseURL: URL)
}

extension SwapAPI: EndpointType {
    public var baseURL: URL {
        switch self {
        case .swap(_, let baseURL):
            return baseURL
        case .swapWithAccessToken(_, let baseURL):
            return baseURL
        }
    }
    
    var path: String {
        switch self {
        case .swap, .swapWithAccessToken:
            return "/v1/swap"
        }
    }
    
    var httpMethod: HTTPMethod {
        switch self {
        case .swap, .swapWithAccessToken:
            return .post
        }
    }
    
    var task: HTTPTask {
        switch self {
        case .swap(let request, _):
            return .requestParameters(encoding: .jsonEncodableEncoding(encodable: request))
        case .swapWithAccessToken(let request, _):
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

/// Extension for easier swap operations
extension SwapService {
    /// Simple swap for sending specific amount
    public func swapToSend(
        from availableProofs: [Proof],
        amount: Int,
        at mintURL: String,
        deterministicOutputs: DeterministicOutputProvider? = nil
    ) async throws -> SwapResult {
        let preparation = try await prepareSwapToSend(
            availableProofs: availableProofs,
            targetAmount: amount,
            at: mintURL,
            deterministicOutputs: deterministicOutputs
        )

        return try await executeCompleteSwap(preparation: preparation, at: mintURL)
    }

    /// Simple swap for receiving tokens
    public func swapToReceive(
        proofs: [Proof],
        at mintURL: String,
        deterministicOutputs: DeterministicOutputProvider? = nil
    ) async throws -> SwapResult {
        let preparation = try await prepareSwapToReceive(
            receivedProofs: proofs,
            at: mintURL,
            deterministicOutputs: deterministicOutputs
        )

        return try await executeCompleteSwap(preparation: preparation, at: mintURL)
    }
}
