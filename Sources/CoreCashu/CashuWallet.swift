//
//  CashuWallet.swift
//  CashuKit
//
//  Main wallet implementation for Cashu operations
//

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import P256K

// MARK: - Wallet Configuration

/// Configuration for the Cashu wallet
public struct WalletConfiguration: Sendable {
    public let mintURL: String
    public let unit: String
    public let retryAttempts: Int
    public let retryDelay: TimeInterval
    public let operationTimeout: TimeInterval
    /// Validated mint URL. Guaranteed non-nil because the initializer rejects malformed URLs.
    public let mintURLValue: URL
    #if canImport(Security) && !os(Linux)
    /// Optional Keychain access-control policy to apply when CoreCashu provisions its default secure store on Apple platforms.
    public let keychainAccessControl: KeychainSecureStore.Configuration.AccessControlPolicy?
    internal var keychainConfiguration: KeychainSecureStore.Configuration {
        KeychainSecureStore.Configuration(accessControl: keychainAccessControl)
    }
    #endif

    /// Creates a new wallet configuration.
    /// - Parameters:
    ///   - mintURL: Base URL of the target mint. Must be a syntactically valid `http`/`https` URL.
    ///   - unit: Display unit for balances (defaults to sat).
    ///   - retryAttempts: Maximum retry attempts for idempotent requests.
    ///   - retryDelay: Delay between retries in seconds.
    ///   - operationTimeout: Timeout for network operations in seconds.
    /// - Throws: ``CashuError/invalidMintURL`` if `mintURL` cannot be parsed or has an unsupported scheme.
    #if canImport(Security) && !os(Linux)
    ///   - keychainAccessControl: Optional Keychain access-control policy applied to the default secure store.
    public init(
        mintURL: String,
        unit: String = "sat",
        retryAttempts: Int = 3,
        retryDelay: TimeInterval = 1.0,
        operationTimeout: TimeInterval = 30.0,
        keychainAccessControl: KeychainSecureStore.Configuration.AccessControlPolicy? = nil
    ) throws {
        self.mintURLValue = try Self.validate(mintURL: mintURL)
        self.mintURL = mintURL
        self.unit = unit
        self.retryAttempts = retryAttempts
        self.retryDelay = retryDelay
        self.operationTimeout = operationTimeout
        self.keychainAccessControl = keychainAccessControl
    }
    #else
    public init(
        mintURL: String,
        unit: String = "sat",
        retryAttempts: Int = 3,
        retryDelay: TimeInterval = 1.0,
        operationTimeout: TimeInterval = 30.0
    ) throws {
        self.mintURLValue = try Self.validate(mintURL: mintURL)
        self.mintURL = mintURL
        self.unit = unit
        self.retryAttempts = retryAttempts
        self.retryDelay = retryDelay
        self.operationTimeout = operationTimeout
    }
    #endif

    private static func validate(mintURL: String) throws -> URL {
        guard let url = URL(string: mintURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            throw CashuError.invalidMintURL
        }
        return url
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
/// let config = try WalletConfiguration(
///     mintURL: "https://mint.example.com",
///     unit: "sat"
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
    
    public let configuration: WalletConfiguration
    internal let proofManager: ProofManager
    internal let mintInfoService: MintInfoService
    
    internal var mintService: MintService?
    internal var meltService: MeltService?
    internal var swapService: SwapService?
    internal var keyExchangeService: KeyExchangeService?
    internal var keysetManagementService: KeysetManagementService?
    internal var checkStateService: CheckStateService?
    internal var accessTokenService: AccessTokenService?
    
    public private(set) var currentMintInfo: MintInfo?
    public private(set) var currentKeysets: [String: Keyset] = [:]
    internal var currentKeysetInfos: [String: KeysetInfo] = [:]
    public private(set) var walletState: WalletState = .uninitialized
    internal var capabilityManager: MintFeatureCapabilityManager?
    
    // NUT-13: Deterministic secrets
    internal var deterministicDerivation: DeterministicSecretDerivation?
    internal let keysetCounterManager: KeysetCounterManager
    
    // Security: Secure storage
    internal let secureStore: (any SecureStore)?
    
    // Logging
    internal let logger: any LoggerProtocol

    // Networking
    internal let networking: any Networking

    // Metrics
    public let metrics: any MetricsClient
    
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
        logger: (any LoggerProtocol)? = nil,
        metrics: (any MetricsClient)? = nil
    ) async {
        self.configuration = configuration
        self.proofManager = ProofManager(storage: proofStorage ?? InMemoryProofStorage())
        let resolvedNetworking: any Networking = networking ?? URLSession.shared
        self.mintInfoService = await MintInfoService(networking: resolvedNetworking)
        self.keysetCounterManager = KeysetCounterManager()
        
        #if canImport(Security) && !os(Linux)
        if let secureStore {
            self.secureStore = secureStore
        } else {
            self.secureStore = KeychainSecureStore(configuration: configuration.keychainConfiguration)
        }
        #else
        // On non-Apple platforms there is no system-protected default secure store. We deliberately
        // do *not* spin up a `FileSecureStore` with no password — that would write the AES key next
        // to the ciphertext and provide no protection against a directory-copy attacker. Linux
        // consumers must inject a `FileSecureStore(password:)` (or another `SecureStore`)
        // explicitly. Operations that need the secure store will throw if it's nil.
        self.secureStore = secureStore
        #endif

        self.networking = resolvedNetworking

        // Use provided logger or default to console logger
        self.logger = logger ?? ConsoleLogger()

        // Use provided metrics or default to no-op
        self.metrics = metrics ?? NoOpMetricsClient()

        // Initialize services
        await setupServices()

        // Counter state is managed in-memory by KeysetCounterManager
    }
    
    /// Initialize wallet with mint URL
    /// - Parameters:
    ///   - mintURL: The mint URL
    ///   - unit: Currency unit (defaults to "sat")
    /// - Throws: ``CashuError/invalidMintURL`` if `mintURL` cannot be parsed.
    public init(
        mintURL: String,
        unit: String = "sat"
    ) async throws {
        let config = try WalletConfiguration(mintURL: mintURL, unit: unit)
        await self.init(configuration: config, networking: URLSession.shared)
    }
    
    /// Initialize wallet with mnemonic phrase (NUT-13).
    ///
    /// This is the canonical initializer; the plaintext mnemonic is held under the
    /// ``SensitiveString`` lock and wiped on the wrapper's deinit.
    ///
    /// - Parameters:
    ///   - configuration: Wallet configuration
    ///   - mnemonic: BIP39 mnemonic phrase, wrapped in ``SensitiveString``
    ///   - passphrase: Optional BIP39 passphrase
    ///   - proofStorage: Optional custom proof storage
    ///   - counterStorage: Optional custom counter storage
    ///   - secureStore: Optional secure storage implementation
    ///   - networking: Optional networking implementation (defaults to URLSession.shared)
    ///   - logger: Optional logger implementation (defaults to console logger)
    public init(
        configuration: WalletConfiguration,
        mnemonic: SensitiveString,
        passphrase: String = "",
        proofStorage: (any ProofStorage)? = nil,
        counterStorage: (any KeysetCounterStorage)? = nil,
        secureStore: (any SecureStore)? = nil,
        networking: (any Networking)? = nil,
        logger: (any LoggerProtocol)? = nil,
        metrics: (any MetricsClient)? = nil
    ) async throws {
        self.configuration = configuration
        self.proofManager = ProofManager(storage: proofStorage ?? InMemoryProofStorage())
        let resolvedNetworking: any Networking = networking ?? URLSession.shared
        self.mintInfoService = await MintInfoService(networking: resolvedNetworking)
        self.keysetCounterManager = KeysetCounterManager()

        #if canImport(Security) && !os(Linux)
        if let secureStore {
            self.secureStore = secureStore
        } else {
            self.secureStore = KeychainSecureStore(configuration: configuration.keychainConfiguration)
        }
        #else
        // See note in the other initializer: no password-less default on non-Apple. Caller
        // must inject `FileSecureStore(password:)` or another `SecureStore`.
        self.secureStore = secureStore
        #endif

        self.networking = resolvedNetworking

        // Use provided logger or default to console logger
        self.logger = logger ?? ConsoleLogger()

        // Use provided metrics or default to no-op
        self.metrics = metrics ?? NoOpMetricsClient()

        // Validate mnemonic BEFORE storing (security: prevents persisting invalid data).
        // The validation lifts the plaintext only inside `withString`'s scope.
        let isValid = await mnemonic.withString { BIP39.validateMnemonic($0) }
        guard isValid else {
            throw CashuError.invalidMnemonic
        }

        // Initialize deterministic derivation (validation passed).
        self.deterministicDerivation = try await DeterministicSecretDerivation(
            mnemonic: mnemonic,
            passphrase: passphrase
        )

        // Store mnemonic securely AFTER validation succeeds. The SecureStore conformer holds
        // the plaintext only inside its own `withString` scope (see protocol doc).
        if let secureStore = self.secureStore {
            try await secureStore.saveMnemonic(mnemonic)
        }

        // Initialize services
        await setupServices()

        // Counter state is managed in-memory by KeysetCounterManager
    }

    /// Convenience initializer that accepts a `String` mnemonic and wraps it in
    /// ``SensitiveString`` immediately. Prefer the ``SensitiveString``-typed initializer in
    /// new code — passing a `String` allows the runtime to keep additional copies that
    /// the wrapper cannot wipe.
    public init(
        configuration: WalletConfiguration,
        mnemonic: String,
        passphrase: String = "",
        proofStorage: (any ProofStorage)? = nil,
        counterStorage: (any KeysetCounterStorage)? = nil,
        secureStore: (any SecureStore)? = nil,
        networking: (any Networking)? = nil,
        logger: (any LoggerProtocol)? = nil,
        metrics: (any MetricsClient)? = nil
    ) async throws {
        try await self.init(
            configuration: configuration,
            mnemonic: SensitiveString(mnemonic),
            passphrase: passphrase,
            proofStorage: proofStorage,
            counterStorage: counterStorage,
            secureStore: secureStore,
            networking: networking,
            logger: logger,
            metrics: metrics
        )
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
            let timer = metrics.startTimer()
            await metrics.increment(CashuMetrics.walletInitializeStart, tags: ["mint": configuration.mintURL])
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
            await metrics.increment(CashuMetrics.walletInitializeSuccess, tags: ["mint": configuration.mintURL])
            await timer.stop(metricName: CashuMetrics.walletInitializeDuration, tags: ["mint": configuration.mintURL])
        } catch {
            walletState = .error(error as? CashuError ?? CashuError.invalidMintConfiguration)
            logger.error("Wallet initialization failed: \(error)")
            await metrics.increment(CashuMetrics.walletInitializeFailure, tags: ["mint": configuration.mintURL, "error": String(describing: error)])
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
    
    // Core wallet operations moved to CashuWallet+Transactions.swift
    // Token import/export moved to CashuWallet+Token.swift
    
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
    
    // NUT-13 deterministic secrets moved to CashuWallet+Restore.swift
    
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
            try await secureStore.saveAccessTokenList(tokenStrings, mintURL: configuration.mintURLValue)
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
            let stored = (try? await secureStore.loadAccessTokenList(mintURL: configuration.mintURLValue)) ?? []
            if let tokenString = stored.first {
                // NOTE: Proof reconstruction from stored token string is handled by ProofManager
                return AccessToken(access: tokenString)
            }
        }
        
        return nil
    }
    
    // Mnemonic and restore methods moved to CashuWallet+Restore.swift
    
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

    /// Build a ``DeterministicOutputProvider`` from the wallet's NUT-13 derivation and counter
    /// manager, or `nil` if the wallet was not initialized with a mnemonic.
    ///
    /// Phase 8.3 follow-up — used by mint/swap call sites so issued proofs use deterministic
    /// secrets and `restoreFromSeed` can rediscover them later.
    internal func deterministicOutputProvider() -> DeterministicOutputProvider? {
        guard let derivation = deterministicDerivation else { return nil }
        return DeterministicOutputProvider(
            derivation: derivation,
            counterManager: keysetCounterManager
        )
    }

    /// Setup wallet services
    private func setupServices() async {
        let mint = await MintService(networking: networking)
        let melt = await MeltService(networking: networking)
        let swap = await SwapService(networking: networking)
        let keyExchange = await KeyExchangeService(networking: networking)
        let keysetManagement = await KeysetManagementService(networking: networking)
        let checkState = await CheckStateService(networking: networking)
        
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
        guard let keysetManagementService = keysetManagementService else {
            throw CashuError.walletNotInitialized
        }

        // Refresh keyset metadata first so restore/access-token flows can rely on active flags.
        let keysetInfoResponse = try await keysetManagementService.getKeysets(from: configuration.mintURL)
        currentKeysetInfos = Dictionary(uniqueKeysWithValues: keysetInfoResponse.keysets.map { ($0.id, $0) })

        let keysets = try await keyExchangeService.getActiveKeys(
            from: configuration.mintURL, 
            unit: CurrencyUnit(rawValue: configuration.unit) ?? .sat
        )

        currentKeysets.removeAll()
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
    internal func calculateOptimalDistribution(
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
    internal func isDenominationOptimal(
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

    /// Throws ``CashuError/unsupportedOperation(_:)`` (or the structured
    /// ``CashuError/capabilityNotSupported(mintURL:capability:operation:guidance:)`` form)
    /// if the connected mint hasn't advertised support for the given NUT.
    ///
    /// This is the single chokepoint that wires ``MintFeatureCapabilities`` as a runtime
    /// contract for optional NUTs. Required capabilities (NUT-01/02/03/04/05/06) are not
    /// gated here — the wallet refuses to initialise without them, which is enforced earlier.
    /// Use this for optional NUTs (NUT-07 state check, NUT-09 restore, NUT-11 P2PK,
    /// NUT-14 HTLC, NUT-15 MPP, etc.) before exposing them on the public API.
    ///
    /// - Parameters:
    ///   - capability: The capability the operation requires.
    ///   - operation: Human-readable description of what the caller is trying to do, used in
    ///     the error message. Defaults to `nil` (uses the capability's display name).
    /// - Throws: ``CashuError/walletNotInitialized`` if the wallet hasn't completed
    ///   initialization yet (no `MintInfo` to consult); ``CashuError`` describing the missing
    ///   capability otherwise.
    func requireCapability(
        _ capability: MintFeatureCapability,
        operation: String? = nil
    ) throws {
        guard let capabilityManager else {
            throw CashuError.walletNotInitialized
        }
        guard capabilityManager.isSupported(capability) else {
            throw capabilityManager.unsupportedOperationError(
                capability: capability,
                operation: operation
            )
        }
    }

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
            .clearAuth, .accessTokenAuth, .bolt11PaymentMethod, .http402
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
            // No structured CashuHTTPError body — emit a NetworkErrorContext so callers can
            // inspect the status code (and a capped body prefix for diagnostics) instead of
            // string-parsing "HTTP 500".
            let bodyString = String(data: data, encoding: .utf8)
            throw CashuError.networkFailure(NetworkErrorContext(
                message: "HTTP \(httpResponse.statusCode)",
                httpStatus: httpResponse.statusCode,
                responseBody: bodyString
            ))
        }

        do {
            return try JSONDecoder.cashuDecoder.decode(T.self, from: data)
        } catch let decodingError {
            // Preserve `DecodingError` structure rather than stringifying it. Callers that
            // care can switch on `.wrappedFailure(_, underlying: let err as DecodingError)`.
            throw CashuError.wrappedFailure(
                message: "Failed to decode mint response as \(T.self)",
                underlying: decodingError
            )
        }
    }
}

// Balance and Denomination types moved to CashuWallet+Balance.swift
