//
//  CashuWallet.swift
//  CashuKit
//
//  Main wallet implementation for Cashu operations
//

import Foundation
import P256K
// TODO: Replace BitcoinDevKit with cross-platform BIP39 implementation
// import BitcoinDevKit

// MARK: - Wallet Configuration

/// Configuration for the Cashu wallet
public struct WalletConfiguration: Sendable {
    public let mintURL: String
    public let unit: String
    public let retryAttempts: Int
    public let retryDelay: TimeInterval
    public let operationTimeout: TimeInterval
    
    public init(
        mintURL: String,
        unit: String = "sat",
        retryAttempts: Int = 3,
        retryDelay: TimeInterval = 1.0,
        operationTimeout: TimeInterval = 30.0
    ) {
        self.mintURL = mintURL
        self.unit = unit
        self.retryAttempts = retryAttempts
        self.retryDelay = retryDelay
        self.operationTimeout = operationTimeout
    }
}

// MARK: - Wallet State

/// Current state of the wallet
public enum WalletState: Sendable, Equatable {
    case uninitialized
    case initializing
    case ready
    case syncing
    case error(CashuError)
    
    public static func == (lhs: WalletState, rhs: WalletState) -> Bool {
        switch (lhs, rhs) {
        case (.uninitialized, .uninitialized),
             (.initializing, .initializing),
             (.ready, .ready),
             (.syncing, .syncing):
            return true
        case (.error(let lhsError), .error(let rhsError)):
            return lhsError.localizedDescription == rhsError.localizedDescription
        default:
            return false
        }
    }
}

// MARK: - Wallet Result Types

// Using existing MintResult and MeltResult from NUT services

// MARK: - Cashu Wallet

/// The main Cashu wallet implementation for managing eCash operations.
///
/// `CashuWallet` is a thread-safe actor that provides a complete interface for interacting
/// with Cashu mints. It handles all aspects of the eCash lifecycle including minting,
/// melting, sending, and receiving tokens.
///
/// ## Overview
///
/// The wallet manages:
/// - **Mint Communication**: Connects to and interacts with Cashu mints
/// - **Token Management**: Creates, stores, and validates eCash proofs
/// - **Transaction Processing**: Handles minting, melting, and swapping operations
/// - **State Management**: Tracks wallet state and transaction history
/// - **Security**: Integrates with secure storage for sensitive data
///
/// ## Usage
///
/// Create and initialize a wallet:
///
/// ```swift
/// let config = WalletConfiguration(
///     mintURL: "https://mint.example.com",
///     unit: .sat
/// )
/// 
/// let wallet = await CashuWallet(configuration: config)
/// try await wallet.initializeWallet()
/// ```
///
/// ## Topics
///
/// ### Configuration
/// - ``WalletConfiguration``
/// - ``initializeWallet()``
///
/// ### Token Operations
/// - ``mint(quote:)``
/// - ``melt(quote:proofs:)``
/// - ``send(amount:proofs:)``
/// - ``receive(token:)``
///
/// ### Balance and State
/// - ``getTotalBalance()``
/// - ``checkProofStates(_:)``
/// - ``getAllProofs()``
///
/// - Note: All operations are performed asynchronously and may throw errors.
/// Always handle errors appropriately when calling wallet methods.
///
/// - Important: The wallet actor ensures thread-safe access to all operations.
/// Multiple concurrent operations are automatically serialized.
public actor CashuWallet {
    
    // MARK: - Properties
    
    private let configuration: WalletConfiguration
    private let proofManager: ProofManager
    private let mintInfoService: MintInfoService
    
    private var mintService: MintService?
    private var meltService: MeltService?
    private var swapService: SwapService?
    private var keyExchangeService: KeyExchangeService?
    private var keysetManagementService: KeysetManagementService?
    private var checkStateService: CheckStateService?
    private var accessTokenService: AccessTokenService?
    
    private var currentMintInfo: MintInfo?
    private var currentKeysets: [String: Keyset] = [:]
    private var currentKeysetInfos: [String: KeysetInfo] = [:]
    private var walletState: WalletState = .uninitialized
    private var capabilityManager: MintFeatureCapabilityManager?
    
    // NUT-13: Deterministic secrets
    private var deterministicDerivation: DeterministicSecretDerivation?
    private let keysetCounterManager: KeysetCounterManager
    
    // Security: Secure storage
    private let secureStore: (any SecureStore)?
    
    // Logging
    private let logger: any LoggerProtocol
    
    // Networking
    private let networking: any Networking
    
    // MARK: - Initialization
    
    /// Initialize a new Cashu wallet
    /// - Parameters:
    ///   - configuration: Wallet configuration
    ///   - proofStorage: Optional custom proof storage (defaults to in-memory)
    ///   - counterStorage: Optional custom counter storage
    ///   - secureStore: Optional secure storage implementation (defaults to in-memory)
    ///   - networking: Optional networking implementation (defaults to URLSession.shared)
    ///   - logger: Optional logger implementation (defaults to console logger)
    public init(
        configuration: WalletConfiguration,
        proofStorage: (any ProofStorage)? = nil,
        counterStorage: (any KeysetCounterStorage)? = nil,
        secureStore: (any SecureStore)? = nil,
        networking: (any Networking)? = nil,
        logger: (any LoggerProtocol)? = nil
    ) async {
        self.configuration = configuration
        self.proofManager = ProofManager(storage: proofStorage ?? InMemoryProofStorage())
        self.mintInfoService = await MintInfoService()
        self.keysetCounterManager = KeysetCounterManager()
        
        // Use provided secure store or default to in-memory
        self.secureStore = secureStore
        
        // Use provided networking or default to URLSession.shared
        self.networking = networking ?? URLSession.shared
        
        // Use provided logger or default to console logger
        self.logger = logger ?? ConsoleLogger()
        
        // Initialize services
        await setupServices()
        
        // Counter state is managed in-memory by KeysetCounterManager
    }
    
    /// Initialize wallet with mint URL
    /// - Parameters:
    ///   - mintURL: The mint URL
    ///   - unit: Currency unit (defaults to "sat")
    public init(
        mintURL: String,
        unit: String = "sat"
    ) async {
        let config = WalletConfiguration(mintURL: mintURL, unit: unit)
        await self.init(configuration: config, networking: URLSession.shared)
    }
    
    /// Initialize wallet with mnemonic phrase (NUT-13)
    /// - Parameters:
    ///   - configuration: Wallet configuration
    ///   - mnemonic: BIP39 mnemonic phrase
    ///   - passphrase: Optional BIP39 passphrase
    ///   - proofStorage: Optional custom proof storage
    ///   - counterStorage: Optional custom counter storage
    ///   - secureStore: Optional secure storage implementation
    ///   - networking: Optional networking implementation (defaults to URLSession.shared)
    ///   - logger: Optional logger implementation (defaults to console logger)
    public init(
        configuration: WalletConfiguration,
        mnemonic: String,
        passphrase: String = "",
        proofStorage: (any ProofStorage)? = nil,
        counterStorage: (any KeysetCounterStorage)? = nil,
        secureStore: (any SecureStore)? = nil,
        networking: (any Networking)? = nil,
        logger: (any LoggerProtocol)? = nil
    ) async throws {
        self.configuration = configuration
        self.proofManager = ProofManager(storage: proofStorage ?? InMemoryProofStorage())
        self.mintInfoService = await MintInfoService()
        self.keysetCounterManager = KeysetCounterManager()
        
        // Use provided secure store
        self.secureStore = secureStore
        
        // Use provided networking or default to URLSession.shared
        self.networking = networking ?? URLSession.shared
        
        // Use provided logger or default to console logger
        self.logger = logger ?? ConsoleLogger()
        
        // Store mnemonic securely if secure store is available
        if let secureStore = self.secureStore {
            try await secureStore.saveMnemonic(mnemonic)
        }
        
        // Initialize deterministic derivation
        self.deterministicDerivation = try DeterministicSecretDerivation(
            mnemonic: mnemonic,
            passphrase: passphrase
        )
        
        // Initialize services
        await setupServices()
        
        // Counter state is managed in-memory by KeysetCounterManager
    }
    
    // MARK: - Wallet State Management
    
    /// Get current wallet state
    public var state: WalletState {
        walletState
    }
    
    /// Get mint URL
    public var mintURL: String {
        configuration.mintURL
    }
    
    /// Get currency unit
    public var unit: String {
        configuration.unit
    }
    
    /// Check if wallet is ready for operations
    public var isReady: Bool {
        switch walletState {
        case .ready:
            return true
        default:
            return false
        }
    }
    
    /// Initialize the wallet (fetch mint info and keysets)
    public func initialize() async throws {
        guard case .uninitialized = walletState else {
            logger.warning("Attempted to initialize already initialized wallet")
            throw CashuError.walletAlreadyInitialized
        }
        
        logger.info("Initializing wallet for mint: \(configuration.mintURL)")
        walletState = .initializing
        
        do {
            // Fetch mint information
            logger.debug("Fetching mint information")
            // TODO: Metrics - logger.metricIncrement("cashukit.wallet.initialize.start", tags: ["mint": configuration.mintURL])
            // TODO: Performance logging
            currentMintInfo = try await mintInfoService.getMintInfoWithRetry(
                from: configuration.mintURL,
                maxRetries: configuration.retryAttempts,
                retryDelay: configuration.retryDelay
            )
            
            // Validate mint supports basic operations
            guard let mintInfo = currentMintInfo, mintInfo.supportsBasicOperations() else {
                logger.error("Mint does not support basic operations")
                throw CashuError.invalidMintConfiguration
            }
            
            logger.info("Mint info fetched successfully: \(mintInfo.name ?? "Unknown")")
            
            // Initialize capability manager
            if let mintURL = URL(string: configuration.mintURL) {
                capabilityManager = MintFeatureCapabilityManager(mintInfo: mintInfo, mintURL: mintURL)
            }
            
            // Fetch active keysets
            logger.debug("Syncing keysets")
            try await syncKeysets()
            
            walletState = .ready
            logger.info("Wallet initialized successfully")
            // TODO: Metrics - logger.metricIncrement("cashukit.wallet.initialize.success", tags: ["mint": configuration.mintURL])
        } catch {
            walletState = .error(error as? CashuError ?? CashuError.invalidMintConfiguration)
            logger.error("Wallet initialization failed: \(error)")
            // TODO: Metrics - logger.metricIncrement("cashukit.wallet.initialize.failure", tags: ["mint": configuration.mintURL])
            ErrorAnalytics.logError(error, context: ["operation": "wallet_initialization", "mint": configuration.mintURL])
            throw error
        }
    }
    
    /// Sync wallet state with mint (fetch latest keysets and mint info)
    public func sync() async throws {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        
        let previousState = walletState
        walletState = .syncing
        
        do {
            // Refresh mint info
            currentMintInfo = try await mintInfoService.getMintInfoWithRetry(
                from: configuration.mintURL,
                maxRetries: configuration.retryAttempts,
                retryDelay: configuration.retryDelay
            )
            
            // Sync keysets
            try await syncKeysets()
            
            walletState = .ready
        } catch {
            walletState = previousState
            throw error
        }
    }
    
    // MARK: - Balance Operations
    
    /// Get current wallet balance
    public var balance: Int {
        get async throws {
            guard isReady else {
                throw CashuError.walletNotInitialized
            }
            
            return try await proofManager.getTotalBalance()
        }
    }
    
    /// Get balance by keyset
    public func balance(for keysetID: String) async throws -> Int {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        
        return try await proofManager.getBalance(keysetID: keysetID)
    }
    
    /// Get detailed balance breakdown by keyset
    public func getBalanceBreakdown() async throws -> BalanceBreakdown {
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
    public func getBalanceStream() -> AsyncStream<BalanceUpdate> {
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
    public var proofs: [Proof] {
        get async throws {
            guard isReady else {
                throw CashuError.walletNotInitialized
            }
            
            return try await proofManager.getAvailableProofs()
        }
    }
    
    // MARK: - Denomination Management
    
    /// Get available denominations for the current wallet
    public func getAvailableDenominations() async throws -> [Int] {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        
        let allProofs = try await proofManager.getAvailableProofs()
        let denominations = Set(allProofs.map { $0.amount })
        return Array(denominations).sorted()
    }
    
    /// Get denomination breakdown showing count of each denomination
    public func getDenominationBreakdown() async throws -> DenominationBreakdown {
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
    public func optimizeDenominations(preferredDenominations: [Int]) async throws -> OptimizationResult {
        guard isReady else {
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
        
        // Perform swap operation to optimize denominations
        // This is a simplified approach - in practice, you'd use the swap service
        // to exchange current proofs for optimally-denominated ones
        
        // For now, just return the current state
        return OptimizationResult(
            success: true,
            proofsChanged: false,
            newProofs: allProofs,
            previousDenominations: currentDenominations,
            newDenominations: currentDenominations
        )
    }
    
    /// Get recommended denomination structure for a given amount
    /// - Parameter amount: Target amount to optimize for
    /// - Returns: Recommended denomination breakdown
    public func getRecommendedDenominations(for amount: Int) -> [Int: Int] {
        return DenominationUtils.getOptimalDenominations(amount: amount)
    }
    
    // MARK: - Core Wallet Operations
    
    /// Mint new tokens from a payment request
    /// - Parameters:
    ///   - amount: Amount to mint
    ///   - paymentRequest: Payment request (e.g., Lightning invoice)
    ///   - method: Payment method (defaults to "bolt11")
    /// - Returns: Mint result with new proofs
    public func mint(
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
        
        // Mint service is always available since it's initialized in setupServices()
        
        // Use the existing high-level mint method
        guard let mintService = mintService else {
            throw CashuError.walletNotInitialized
        }
        // TODO: Metrics - logger.metricIncrement("cashukit.mint.start", tags: ["mint": configuration.mintURL, "unit": configuration.unit])
        // TODO: Performance logging
        let result = try await mintService.mint(
            amount: amount,
            method: method,
            unit: configuration.unit,
            at: configuration.mintURL
        )
        // TODO: Metrics - logger.metricIncrement("cashukit.mint.success", tags: ["mint": configuration.mintURL, "unit": configuration.unit])
        return result
    }
    
    /// Send tokens (prepare for transfer)
    /// - Parameters:
    ///   - amount: Amount to send
    ///   - memo: Optional memo
    /// - Returns: Cashu token ready for transfer
    public func send(amount: Int, memo: String? = nil) async throws -> CashuToken {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        
        guard amount > 0 else {
            throw CashuError.invalidAmount
        }
        
        // Simplified implementation - create a basic token structure
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
    public func selectProofsForAmount(_ amount: Int) async throws -> [Proof] {
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
    public func receive(token: CashuToken) async throws -> [Proof] {
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
    public func melt(
        paymentRequest: String,
        method: String = "bolt11"
    ) async throws -> MeltResult {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        
        // Melt service is always available since it's initialized in setupServices()
        
        // Prepare melt to know exactly which proofs will be used
        let availableProofs = try await proofManager.getAvailableProofs()
        guard let meltService = meltService else { throw CashuError.walletNotInitialized }

        let preparation = try await meltService.prepareMelt(
            paymentRequest: paymentRequest,
            method: PaymentMethod(rawValue: method) ?? .bolt11,
            unit: configuration.unit,
            availableProofs: availableProofs,
            at: configuration.mintURL
        )

        // Mark selected proofs as pending spent
        try await proofManager.markAsPendingSpent(preparation.inputProofs)

        // TODO: Metrics - logger.metricIncrement("cashukit.melt.start", tags: ["mint": configuration.mintURL, "unit": configuration.unit])
        do {
            // TODO: Performance logging
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
                // TODO: Metrics - logger.metricIncrement("cashukit.melt.finalized", tags: ["mint": configuration.mintURL])
            } else {
                try await proofManager.rollbackPendingSpent(preparation.inputProofs)
                // TODO: Metrics - logger.metricIncrement("cashukit.melt.rolled_back", tags: ["mint": configuration.mintURL, "state": String(describing: result.state)])
            }

            return result
        } catch {
            try await proofManager.rollbackPendingSpent(preparation.inputProofs)
            // TODO: Metrics - logger.metricIncrement("cashukit.melt.error", tags: ["mint": configuration.mintURL])
            throw error
        }
    }
    
    // MARK: - Token Import/Export
    
    /// Import a token from a serialized string
    /// - Parameter serializedToken: The serialized token string
    /// - Returns: Array of imported proofs
    public func importToken(_ serializedToken: String) async throws -> [Proof] {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        
        // Deserialize the token
        let token = try CashuTokenUtils.deserializeToken(serializedToken)
        
        // Validate the token
        let validationResult = ValidationUtils.validateCashuToken(token)
        guard validationResult.isValid else {
            throw CashuError.invalidTokenStructure
        }
        
        // Receive the token (this will add proofs to our storage)
        return try await receive(token: token)
    }
    
    /// Export a token with specified amount
    /// - Parameters:
    ///   - amount: Amount to export
    ///   - memo: Optional memo for the token
    ///   - version: Token version (defaults to V3)
    ///   - includeURI: Whether to include the URI scheme
    /// - Returns: Serialized token string
    public func exportToken(
        amount: Int,
        memo: String? = nil,
        version: TokenVersion = .v3,
        includeURI: Bool = false
    ) async throws -> String {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        
        // Create the token
        let token = try await send(amount: amount, memo: memo)
        
        // Serialize the token
        return try CashuTokenUtils.serializeToken(token, version: version, includeURI: includeURI)
    }
    
    /// Export all available tokens
    /// - Parameters:
    ///   - memo: Optional memo for the token
    ///   - version: Token version (defaults to V3)
    ///   - includeURI: Whether to include the URI scheme
    /// - Returns: Serialized token string
    public func exportAllTokens(
        memo: String? = nil,
        version: TokenVersion = .v3,
        includeURI: Bool = false
    ) async throws -> String {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        
        let totalBalance = try await balance
        guard totalBalance > 0 else {
            throw CashuError.balanceInsufficient
        }
        
        return try await exportToken(
            amount: totalBalance,
            memo: memo,
            version: version,
            includeURI: includeURI
        )
    }
    
    /// Create a token from existing proofs
    /// - Parameters:
    ///   - proofs: Proofs to include in the token
    ///   - memo: Optional memo for the token
    /// - Returns: CashuToken containing the proofs
    public func createToken(from proofs: [Proof], memo: String? = nil) async throws -> CashuToken {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        
        guard !proofs.isEmpty else {
            throw CashuError.noSpendableProofs
        }
        
        // Validate proofs
        let validationResult = ValidationUtils.validateProofs(proofs)
        guard validationResult.isValid else {
            throw CashuError.invalidProofSet
        }
        
        let tokenEntry = TokenEntry(
            mint: configuration.mintURL,
            proofs: proofs
        )
        
        return CashuToken(
            token: [tokenEntry],
            unit: configuration.unit,
            memo: memo
        )
    }
    
    // MARK: - NUT-07: Token state check
    
    /// Check the state of specific proofs (NUT-07)
    /// - Parameter proofs: Array of proofs to check
    /// - Returns: BatchStateCheckResult with the state of each proof
    public func checkProofStates(_ proofs: [Proof]) async throws -> BatchStateCheckResult {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        
        guard !proofs.isEmpty else {
            throw CashuError.invalidProofSet
        }
        
        let request = try PostCheckStateRequest(proofs: proofs)
        let response = try await executeCheckState(request)
        
        var results: [StateCheckResult] = []
        
        for (index, proof) in proofs.enumerated() {
            guard index < response.states.count else {
                throw NUT07Error.stateCheckFailed("Response missing state for proof at index \(index)")
            }
            
            let stateInfo = response.states[index]
            
            let proofY = try proof.calculateY()
            guard stateInfo.Y.lowercased() == proofY.lowercased() else {
                throw NUT07Error.proofYMismatch(expected: proofY, actual: stateInfo.Y)
            }
            
            results.append(StateCheckResult(proof: proof, stateInfo: stateInfo))
        }
        
        return BatchStateCheckResult(results: results)
    }
    
    /// Check the state of a single proof (NUT-07)
    /// - Parameter proof: The proof to check
    /// - Returns: StateCheckResult with the proof state
    public func checkProofState(_ proof: Proof) async throws -> StateCheckResult {
        let batchResult = try await checkProofStates([proof])
        guard let result = batchResult.results.first else {
            throw NUT07Error.stateCheckFailed("No result returned for proof")
        }
        return result
    }
    
    /// Check states of proofs by their Y values (NUT-07)
    /// - Parameter yValues: Array of Y values to check
    /// - Returns: PostCheckStateResponse with the state information
    public func checkStates(yValues: [String]) async throws -> PostCheckStateResponse {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        
        guard !yValues.isEmpty else {
            throw CashuError.validationFailed
        }
        
        let request = PostCheckStateRequest(Ys: yValues)
        return try await executeCheckState(request)
    }
    
    /// Check if mint supports token state checking (NUT-07)
    /// - Returns: True if NUT-07 is supported
    public func supportsStateCheck() -> Bool {
        return currentMintInfo?.isNUTSupported("7") ?? false
    }
    
    /// Execute the checkstate API call
    private func executeCheckState(_ request: PostCheckStateRequest) async throws -> PostCheckStateResponse {
        guard supportsStateCheck() else {
            if let capabilityManager = capabilityManager {
                throw capabilityManager.unsupportedOperationError(
                    capability: .stateCheck,
                    operation: "Check token state"
                )
            } else {
                throw CashuError.unsupportedOperation("State check (NUT-07) is not supported by this mint")
            }
        }
        
        // Check state service is always available since it's initialized in setupServices()
        guard let checkStateService = checkStateService else {
            throw CashuError.walletNotInitialized
        }
        return try await checkStateService.checkStates(yValues: request.Ys, from: configuration.mintURL)
    }
    
    // MARK: - Utility Methods
    
    /// Get mint information
    public var mintInfo: MintInfo? {
        currentMintInfo
    }
    
    /// Get current keysets
    public var keysets: [String: Keyset] {
        currentKeysets
    }
    
    /// Clear all wallet data
    public func clearAll() async throws {
        try await proofManager.clearAll()
        currentMintInfo = nil
        currentKeysets.removeAll()
        currentKeysetInfos.removeAll()
        walletState = .uninitialized
    }
    
    /// Get wallet statistics
    public func getStatistics() async throws -> WalletStatistics {
        let totalBalance = try await proofManager.getTotalBalance()
        let proofCount = try await proofManager.getProofCount()
        let spentProofCount = await proofManager.getSpentProofCount()
        
        return WalletStatistics(
            totalBalance: totalBalance,
            proofCount: proofCount,
            spentProofCount: spentProofCount,
            keysetCount: currentKeysets.count,
            mintURL: configuration.mintURL
        )
    }
    
    // MARK: - NUT-13: Deterministic Secrets
    
    /// Check if wallet supports deterministic secrets
    public var supportsDeterministicSecrets: Bool {
        return deterministicDerivation != nil
    }
    
    // MARK: - Access Token Management (NUT-22)
    
    /// Request access tokens from the mint after a successful mint operation
    /// - Parameters:
    ///   - quoteId: The quote ID from a successful mint operation
    ///   - amount: Number of access tokens to request
    /// - Returns: Array of access token proofs
    @discardableResult
    public func requestAccessTokens(quoteId: String, amount: Int) async throws -> [Proof] {
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        
        // Access token service is always available since it's initialized in setupServices()
        
        // Check if mint requires access tokens
        guard let mintInfo = currentMintInfo,
              mintInfo.supportsNUT22,
              let nut22Settings = mintInfo.getNUT22Settings(),
              (nut22Settings.mandatory || nut22Settings.requiresAccessToken(for: "/v1/swap")) else {
            // Mint doesn't require access tokens
            return []
        }
        
        // Get active keyset for access tokens
        guard let activeKeyset = currentKeysetInfos.values.first(where: { $0.active }) else {
            throw CashuError.noActiveKeyset
        }
        
        guard let accessTokenService = accessTokenService else {
            throw CashuError.walletNotInitialized
        }
        let tokens = try await accessTokenService.requestAccessTokens(
            mintURL: configuration.mintURL,
            quoteId: quoteId,
            amount: amount,
            keysetId: activeKeyset.id
        )
        
        // Store access tokens securely if secure store is available
        if let secureStore = secureStore {
            let tokenStrings = tokens.map { $0.secret }
            try await secureStore.saveAccessTokenList(tokenStrings, mintURL: URL(string: configuration.mintURL)!)
        }
        
        return tokens
    }
    
    /// Check if the mint requires access tokens
    public var requiresAccessTokens: Bool {
        guard let mintInfo = currentMintInfo,
              mintInfo.supportsNUT22,
              let nut22Settings = mintInfo.getNUT22Settings() else {
            return false
        }
        
        return nut22Settings.mandatory || nut22Settings.requiresAccessToken(for: "/v1/swap")
    }
    
    /// Get an available access token for operations
    public func getAccessToken() async -> AccessToken? {
        // Access token service is always available since it's initialized in setupServices()
        
        // First try to get from the service's memory
        guard let accessTokenService = accessTokenService else {
            return nil
        }
        if let proof = await accessTokenService.getAccessToken(for: configuration.mintURL) {
            return AccessToken(access: proof.secret)
        }
        
        // Try to load from secure store if available
        if let secureStore = secureStore {
            let stored = (try? await secureStore.loadAccessTokenList(mintURL: URL(string: configuration.mintURL)!)) ?? []
            if let tokenString = stored.first {
                // TODO: Reconstruct proof from stored token string
                return AccessToken(access: tokenString)
            }
        }
        
        return nil
    }
    
    /// Generate a new mnemonic phrase
    /// - Parameter strength: Strength in bits (128, 160, 192, 224, or 256)
    /// - Returns: BIP39 mnemonic phrase
    public static func generateMnemonic(strength: Int = 128) throws -> String {
        // Convert int strength to BIP39.Strength enum
        guard let bip39Strength = BIP39.Strength(rawValue: strength) else {
            throw CashuError.invalidMnemonic
        }
        
        // Generate mnemonic using BIP39 implementation
        return try BIP39.generateMnemonic(strength: bip39Strength)
    }
    
    /// Validate a mnemonic phrase
    /// - Parameter mnemonic: The mnemonic phrase to validate
    /// - Returns: True if valid
    public static func validateMnemonic(_ mnemonic: String) -> Bool {
        return BIP39.validateMnemonic(mnemonic)
    }
    
    /// Initialize wallet from secure store (restore existing wallet)
    /// - Parameters:
    ///   - configuration: Wallet configuration
    ///   - passphrase: Optional BIP39 passphrase
    ///   - proofStorage: Optional custom proof storage
    ///   - counterStorage: Optional custom counter storage
    ///   - secureStore: Secure storage implementation to restore from
    /// - Returns: A new wallet instance
    /// - Throws: If no mnemonic is stored in secure store
    public static func restoreFromSecureStore(
        configuration: WalletConfiguration,
        passphrase: String = "",
        proofStorage: (any ProofStorage)? = nil,
        counterStorage: (any KeysetCounterStorage)? = nil,
        secureStore: any SecureStore
    ) async throws -> CashuWallet {
        guard let mnemonic = try await secureStore.loadMnemonic() else {
            throw CashuError.noKeychainData
        }
        
        return try await CashuWallet(
            configuration: configuration,
            mnemonic: mnemonic,
            passphrase: passphrase,
            proofStorage: proofStorage,
            counterStorage: counterStorage,
            secureStore: secureStore
        )
    }
    
    /// Restore wallet from seed phrase (NUT-13)
    /// - Parameters:
    ///   - batchSize: Number of proofs to restore per batch (default 100)
    ///   - onProgress: Progress callback
    /// - Returns: Total restored balance
    @discardableResult
    public func restoreFromSeed(
        batchSize: Int = 100,
        onProgress: ((RestorationProgress) async -> Void)? = nil
    ) async throws -> Int {
        guard let derivation = deterministicDerivation else {
            throw CashuError.walletNotInitializedWithMnemonic
        }
        
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        
        let restoration = WalletRestoration(
            derivation: derivation,
            counterManager: keysetCounterManager
        )
        
        var totalRestoredBalance = 0
        var restorationErrors: [String: any Error] = [:]
        
        // Restore for each active keyset
        for (keysetID, _) in currentKeysets {
            guard currentKeysetInfos[keysetID]?.active ?? false else {
                continue
            }
            
            do {
                let balance = try await restoreKeyset(
                    keysetID: keysetID,
                    restoration: restoration,
                    batchSize: batchSize,
                    onProgress: onProgress
                )
                totalRestoredBalance += balance
            } catch {
                // Store error but continue with other keysets
                restorationErrors[keysetID] = error
                
                // Report error in progress
                if let onProgress = onProgress {
                    let progress = RestorationProgress(
                        keysetID: keysetID,
                        currentCounter: 0,
                        totalProofsFound: 0,
                        unspentProofsFound: 0,
                        consecutiveEmptyBatches: 0,
                        isComplete: true,
                        error: error
                    )
                    await onProgress(progress)
                }
            }
        }
        
        // If all keysets failed, throw the first error
        if restorationErrors.count == currentKeysets.count,
           let firstError = restorationErrors.values.first {
            throw firstError
        }
        
        return totalRestoredBalance
    }
    
    /// Restore a single keyset
    private func restoreKeyset(
        keysetID: String,
        restoration: WalletRestoration,
        batchSize: Int,
        onProgress: ((RestorationProgress) async -> Void)?
    ) async throws -> Int {
        var totalRestoredBalance = 0
        var consecutiveEmptyBatches = 0
        var currentCounter = await keysetCounterManager.getCounter(for: keysetID)
        var totalProofsFound = 0
        var unspentProofsFound = 0
        
        while consecutiveEmptyBatches < 3 {
                // Generate blinded messages for this batch
                let blindedMessagesWithFactors = try await restoration.generateBlindedMessages(
                    keysetID: keysetID,
                    startCounter: currentCounter,
                    batchSize: batchSize
                )
                
                let blindedMessages = blindedMessagesWithFactors.map { $0.0 }
                let blindingFactors = blindedMessagesWithFactors.map { $0.1 }
                
                // Request signatures from mint using NUT-09
                let blindedSignatures = try await requestRestore(
                    blindedMessages: blindedMessages,
                    keysetID: keysetID
                )
                
                if blindedSignatures.isEmpty {
                    consecutiveEmptyBatches += 1
                } else {
                    consecutiveEmptyBatches = 0
                    
                    // Generate secrets for unblinding
                    var secrets: [String] = []
                    for i in 0..<blindedSignatures.count {
                        let secret = try restoration.derivation.deriveSecret(
                            keysetID: keysetID,
                            counter: currentCounter + UInt32(i)
                        )
                        secrets.append(secret)
                    }
                    
                    // Get mint public key for the first amount (assuming single denomination restore)
                    // In a real implementation, you'd match the proper key for each amount
                    guard let keyset = currentKeysets[keysetID],
                          let firstAmount = blindedSignatures.first?.amount,
                          let publicKeyHex = keyset.keys[String(firstAmount)],
                          let publicKeyData = Data(hexString: publicKeyHex),
                          let mintPublicKey = try? P256K.KeyAgreement.PublicKey(dataRepresentation: publicKeyData, format: .compressed) else {
                        throw CashuError.keysetNotFound
                    }
                    
                    // Restore proofs
                    let restoredProofs = try restoration.restoreProofs(
                        blindedSignatures: blindedSignatures,
                        blindingFactors: Array(blindingFactors.prefix(blindedSignatures.count)),
                        secrets: secrets,
                        keysetID: keysetID,
                        mintPublicKey: mintPublicKey
                    )
                    
                    // Check proof states
                    let stateResult = try await checkProofStates(restoredProofs)
                    
                    // Separate spent and unspent proofs
                    var unspentProofs: [Proof] = []
                    for result in stateResult.results {
                        if result.stateInfo.state == .unspent {
                            unspentProofs.append(result.proof)
                        }
                    }
                    
                    // Add unspent proofs to wallet
                    if !unspentProofs.isEmpty {
                        try await proofManager.addProofs(unspentProofs)
                        totalRestoredBalance += unspentProofs.reduce(0) { $0 + $1.amount }
                        unspentProofsFound += unspentProofs.count
                    }
                    
                    totalProofsFound += restoredProofs.count
                }
                
                currentCounter += UInt32(batchSize)
                
                // Report progress
                if let onProgress = onProgress {
                    let progress = RestorationProgress(
                        keysetID: keysetID,
                        currentCounter: currentCounter,
                        totalProofsFound: totalProofsFound,
                        unspentProofsFound: unspentProofsFound,
                        consecutiveEmptyBatches: consecutiveEmptyBatches,
                        isComplete: false
                    )
                    await onProgress(progress)
                }
            }
            
            // Update counter for this keyset
            let finalCounter = currentCounter - UInt32(3 * batchSize) + UInt32(totalProofsFound)
            await keysetCounterManager.setCounter(for: keysetID, value: finalCounter + 1)
            
            // Counters are managed in-memory
            
            // Report completion for this keyset
            if let onProgress = onProgress {
                let progress = RestorationProgress(
                    keysetID: keysetID,
                    currentCounter: finalCounter,
                    totalProofsFound: totalProofsFound,
                    unspentProofsFound: unspentProofsFound,
                    consecutiveEmptyBatches: 3,
                    isComplete: true
                )
                await onProgress(progress)
            }
        
        return totalRestoredBalance
    }
    
    /// Request restore from mint (NUT-09)
    private func requestRestore(
        blindedMessages: [BlindedMessage],
        keysetID: String
    ) async throws -> [BlindSignature] {
        // Check if mint supports NUT-09
        guard currentMintInfo?.isNUTSupported("9") ?? false else {
            if let capabilityManager = capabilityManager {
                throw capabilityManager.unsupportedOperationError(
                    capability: .restore,
                    operation: "Restore proofs from backup"
                )
            } else {
                throw CashuError.unsupportedOperation("Restore functionality (NUT-09) is not supported by this mint")
            }
        }
        
        // Create restore service
        let restoreService = await RestoreSignatureService()
        
        // Request restore from mint
        let request = PostRestoreRequest(outputs: blindedMessages)
        let response = try await restoreService.restoreSignatures(request: request, mintURL: configuration.mintURL)
        
        // Extract signatures from response
        return response.signatures
    }
    
    /// Get current keyset counters
    public func getKeysetCounters() async -> [String: UInt32] {
        return await keysetCounterManager.getAllCounters()
    }
    
    /// Get swap service instance
    public func getSwapService() async -> SwapService? {
        return swapService
    }
    
    /// Get key exchange service instance
    public func getKeyExchangeService() async -> KeyExchangeService? {
        return keyExchangeService
    }
    
    /// Get active keysets
    public func getActiveKeysets() async throws -> [Keyset] {
        // Key exchange service is always available since it's initialized in setupServices()
        guard let keyExchangeService = keyExchangeService else {
            throw CashuError.walletNotInitialized
        }
        return try await keyExchangeService.getActiveKeysets(from: configuration.mintURL)
    }
    
    /// Get mint keys dictionary
    /// Note: This returns the internal structure needed for unblinding operations
    internal func getMintKeys() async throws -> [String: P256K.KeyAgreement.PublicKey] {
        // Key exchange service is always available since it's initialized in setupServices()
        
        guard let keyExchangeService = keyExchangeService else {
            throw CashuError.walletNotInitialized
        }
        let keyResponse = try await keyExchangeService.getKeys(from: configuration.mintURL)
        return Dictionary(uniqueKeysWithValues: keyResponse.keysets.flatMap { keyset in
            keyset.keys.compactMap { (amountStr, publicKeyHex) -> (String, P256K.KeyAgreement.PublicKey)? in
                guard let amount = Int(amountStr),
                      let publicKeyData = Data(hexString: publicKeyHex),
                      let publicKey = try? P256K.KeyAgreement.PublicKey(dataRepresentation: publicKeyData, format: .compressed) else {
                    return nil
                }
                return ("\(keyset.id)_\(amount)", publicKey)
            }
        })
    }
    
    // MARK: - Private Methods
    
    /// Setup wallet services
    private func setupServices() async {
        let mint = await MintService()
        let melt = await MeltService()
        let swap = await SwapService()
        let keyExchange = await KeyExchangeService()
        let keysetManagement = await KeysetManagementService()
        let checkState = await CheckStateService()
        
        // Initialize NUT-22 access token service
        // Create a simple network service adapter
        let networkService = SimpleNetworkService(baseURL: configuration.mintURL, networking: networking)
        let accessToken = AccessTokenService(
            networkService: networkService,
            keyExchangeService: keyExchange
        )
        
        // Assign all services atomically
        mintService = mint
        meltService = melt
        swapService = swap
        keyExchangeService = keyExchange
        keysetManagementService = keysetManagement
        checkStateService = checkState
        accessTokenService = accessToken
    }
    
    /// Sync keysets with mint
    private func syncKeysets() async throws {
        // Key exchange service is always available since it's initialized in setupServices()
        
        // Use the existing method to get active keys
        guard let keyExchangeService = keyExchangeService else {
            throw CashuError.walletNotInitialized
        }
        let keysets = try await keyExchangeService.getActiveKeys(
            from: configuration.mintURL, 
            unit: CurrencyUnit(rawValue: configuration.unit) ?? .sat
        )
        
        for keyset in keysets {
            currentKeysets[keyset.id] = keyset
        }
    }
    
    /// Generate blinded outputs for a given amount (messages only)
    private func generateBlindedOutputs(amount: Int) async throws -> [BlindedMessage] {
        let (messages, _) = try await generateBlindedOutputsWithBlindingData(amount: amount)
        return messages
    }

    /// Generate blinded outputs for a given amount, returning messages and their corresponding blinding data
    private func generateBlindedOutputsWithBlindingData(amount: Int) async throws -> ([BlindedMessage], [WalletBlindingData]) {
        // Create optimal denominations (powers of 2)
        let outputAmounts = createOptimalDenominations(for: amount)

        // Get active keyset
        guard let keyExchangeService = keyExchangeService else {
            throw CashuError.walletNotInitialized
        }
        let activeKeysets = try await keyExchangeService.getActiveKeysets(from: configuration.mintURL)
        guard let activeKeyset = activeKeysets.first(where: { $0.unit == configuration.unit }) else {
            throw CashuError.keysetInactive
        }

        // Generate blinded messages and capture blinding data for later unblinding
        var blindedMessages: [BlindedMessage] = []
        var blindingData: [WalletBlindingData] = []

        for outputAmount in outputAmounts {
            let secret = try CashuKeyUtils.generateRandomSecret()
            let walletBlindingData = try WalletBlindingData(secret: secret)
            let blindedMessage = BlindedMessage(
                amount: outputAmount,
                id: activeKeyset.id,
                B_: walletBlindingData.blindedMessage.dataRepresentation.hexString
            )

            blindedMessages.append(blindedMessage)
            blindingData.append(walletBlindingData)
        }

        return (blindedMessages, blindingData)
    }
    
    /// Unblind signatures received from the mint using corresponding blinding data
    private func unblindSignatures(signatures: [BlindSignature], blindingData: [WalletBlindingData]) async throws -> [Proof] {
        // Get mint keys
        // Key exchange service is always available since it's initialized in setupServices()
        
        guard let keyExchangeService = keyExchangeService else {
            throw CashuError.walletNotInitialized
        }
        let keyResponse = try await keyExchangeService.getKeys(from: configuration.mintURL)
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
        
        guard signatures.count == blindingData.count else {
            throw CashuError.invalidResponse
        }

        var newProofs: [Proof] = []

        for (index, signature) in signatures.enumerated() {
            let blinding = blindingData[index]
            let mintKeyKey = "\(signature.id)_\(signature.amount)"

            guard let mintPublicKey = mintKeys[mintKeyKey] else {
                throw CashuError.invalidSignature("Mint public key not found for amount \(signature.amount)")
            }

            guard let blindedSignatureData = Data(hexString: signature.C_) else {
                throw CashuError.invalidHexString
            }

            let unblindedToken = try Wallet.unblindSignature(
                blindedSignature: blindedSignatureData,
                blindingData: blinding,
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

        return newProofs
    }
    
    /// Placeholder for future implementation
    private func rollbackSpentProofs(_ proofs: [Proof]) async throws {
        // This would be implemented in ProofManager
        logger.warning("Need to implement rollback for proofs")
    }
    
    /// Execute operation with timeout
    private func withTimeout<T: Sendable>(_ timeout: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                return try await operation()
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw CashuError.operationTimeout
            }
            
            defer { group.cancelAll() }
            
            guard let result = try await group.next() else {
                throw CashuError.operationTimeout
            }
            
            return result
        }
    }
    
    /// Calculate optimal denomination distribution
    private func calculateOptimalDistribution(
        totalValue: Int, 
        preferredDenominations: [Int]
    ) -> [Int: Int] {
        var remainingAmount = totalValue
        var result: [Int: Int] = [:]
        
        // Sort preferred denominations in descending order
        let sortedDenominations = preferredDenominations.sorted(by: >)
        
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
    
    /// Check if current denomination is optimal
    private func isDenominationOptimal(
        current: [Int: Int],
        optimal: [Int: Int]
    ) -> Bool {
        // Simple comparison - in practice, you might allow some tolerance
        return current == optimal
    }
    
    /// Create optimal denominations for an amount (powers of 2)
    private func createOptimalDenominations(for amount: Int) -> [Int] {
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

// MARK: - Feature Probing API

public extension CashuWallet {
    /// Check if a specific capability is supported by the mint
    func isCapabilitySupported(_ capability: MintFeatureCapability) -> Bool {
        return capabilityManager?.isSupported(capability) ?? false
    }
    
    /// Get all supported capabilities
    func getSupportedCapabilities() -> Set<MintFeatureCapability> {
        return capabilityManager?.supportedCapabilities() ?? []
    }
    
    /// Get missing required capabilities
    func getMissingRequiredCapabilities() -> Set<MintFeatureCapability> {
        return capabilityManager?.missingRequiredCapabilities() ?? []
    }
    
    /// Create a feature probe for a specific capability
    func createFeatureProbe(for capability: MintFeatureCapability) -> (any FeatureProbe)? {
        guard let capabilityManager = capabilityManager else { return nil }
        let factory = FeatureProbeFactory(capabilityManager: capabilityManager)
        return factory.probe(for: capability)
    }
    
    /// Execute an operation with capability checking and fallback
    func executeWithCapabilityCheck<T: Sendable>(
        capability: MintFeatureCapability,
        operation: @Sendable () async throws -> T,
        fallback: (@Sendable () async throws -> T)? = nil
    ) async throws -> T {
        guard let probe = createFeatureProbe(for: capability) else {
            // No capability manager, try the operation anyway
            return try await operation()
        }
        
        if await probe.isAvailable() {
            return try await operation()
        } else if let fallback = fallback {
            logger.info("Capability \(capability.name) not available, using fallback")
            return try await fallback()
        } else {
            if let capabilityManager = capabilityManager {
                throw capabilityManager.unsupportedOperationError(
                    capability: capability,
                    operation: nil
                )
            } else {
                throw CashuError.unsupportedOperation("Capability \(capability.name) not supported")
            }
        }
    }
    
    /// Get a detailed capability report
    func getCapabilityReport() -> String {
        guard let capabilityManager = capabilityManager else {
            return "Capability information not available"
        }
        
        let supported = capabilityManager.supportedCapabilities()
        let allCapabilities: [MintFeatureCapability] = [
            .mintInfo, .keysets, .mintTokens, .meltTokens, .swap,
            .stateCheck, .restore, .p2pk, .dleq, .deterministicSecrets,
            .htlc, .mpp, .overpayOutputSelection, .websockets,
            .paymentRequests, .singleUse, .signatureMintQuotes,
            .preMint, .accessTokenAuth, .proofOfReserves, .http402
        ]
        
        var report = "Mint Capability Report\n"
        report += "=====================\n"
        report += "Mint URL: \(configuration.mintURL)\n\n"
        report += "Required Capabilities:\n"
        
        let required: [MintFeatureCapability] = [.mintInfo, .keysets, .mintTokens, .meltTokens, .swap]
        for cap in required {
            let status = supported.contains(cap) ? "✓" : "✗"
            report += "  \(status) NUT-\(cap.nutID): \(cap.name)\n"
        }
        
        report += "\nOptional Capabilities:\n"
        for cap in allCapabilities where !required.contains(cap) {
            let status = supported.contains(cap) ? "✓" : "✗"
            report += "  \(status) NUT-\(cap.nutID): \(cap.name)\n"
        }
        
        return report
    }
}

// MARK: - Wallet Statistics

/// Wallet statistics and info
public struct WalletStatistics: Sendable {
    public let totalBalance: Int
    public let proofCount: Int
    public let spentProofCount: Int
    public let keysetCount: Int
    public let mintURL: String
    
    public init(
        totalBalance: Int,
        proofCount: Int,
        spentProofCount: Int,
        keysetCount: Int,
        mintURL: String
    ) {
        self.totalBalance = totalBalance
        self.proofCount = proofCount
        self.spentProofCount = spentProofCount
        self.keysetCount = keysetCount
        self.mintURL = mintURL
    }
}

// MARK: - Simple Network Service

/// Simple network service implementation for CashuWallet
private struct SimpleNetworkService: NetworkService {
    let baseURL: String
    let networking: any Networking
    
    init(baseURL: String, networking: any Networking) {
        self.baseURL = baseURL
        self.networking = networking
    }
    
    func execute<T: CashuCodabale>(method: String, path: String, payload: Data?) async throws -> T {
        guard let url = URL(string: baseURL)?.appendingPathComponent(path) else {
            throw CashuError.invalidMintURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        
        let (data, response) = try await networking.data(for: request, delegate: nil)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CashuError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorResponse = try? JSONDecoder().decode(CashuHTTPError.self, from: data) {
                throw CashuError.httpError(detail: errorResponse.detail, code: errorResponse.code)
            }
            throw CashuError.networkError("HTTP \(httpResponse.statusCode)")
        }
        
        return try JSONDecoder.cashuDecoder.decode(T.self, from: data)
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
