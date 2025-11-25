import Foundation

/// Protocol for metrics collection and telemetry
/// Implementations can integrate with various metrics backends like StatsD, Prometheus, CloudWatch, etc.
///
/// This protocol follows NUT-00..NUT-24 specifications for Cashu protocol observability
public protocol MetricsClient: Sendable {

    /// Record a counter metric (increments by 1)
    /// - Parameters:
    ///   - name: Metric name (e.g., "cashu.wallet.mint.success")
    ///   - tags: Optional tags for the metric
    func increment(_ name: String, tags: [String: String]) async

    /// Record a gauge metric (absolute value)
    /// - Parameters:
    ///   - name: Metric name (e.g., "cashu.wallet.balance")
    ///   - value: The gauge value
    ///   - tags: Optional tags for the metric
    func gauge(_ name: String, value: Double, tags: [String: String]) async

    /// Record a histogram/timing metric
    /// - Parameters:
    ///   - name: Metric name (e.g., "cashu.wallet.mint.duration")
    ///   - duration: The duration in seconds
    ///   - tags: Optional tags for the metric
    func timing(_ name: String, duration: TimeInterval, tags: [String: String]) async

    /// Start a timer for measuring duration
    /// - Returns: A timer instance that can be stopped to record the duration
    func startTimer() -> any MetricTimer

    /// Record an event with optional metadata
    /// - Parameters:
    ///   - name: Event name
    ///   - metadata: Optional metadata for the event
    func event(_ name: String, metadata: [String: Any]?) async

    /// Flush any buffered metrics
    func flush() async
}

/// Timer for measuring operation durations
public protocol MetricTimer: Sendable {
    /// Stop the timer and record the metric
    /// - Parameters:
    ///   - metricName: Name of the metric to record
    ///   - tags: Optional tags for the metric
    func stop(metricName: String, tags: [String: String]) async

    /// Get elapsed time without stopping the timer
    var elapsedTime: TimeInterval { get }
}

// MARK: - Default Extension

public extension MetricsClient {
    /// Convenience method for increment without tags
    func increment(_ name: String) async {
        await increment(name, tags: [:])
    }

    /// Convenience method for gauge without tags
    func gauge(_ name: String, value: Double) async {
        await gauge(name, value: value, tags: [:])
    }

    /// Convenience method for timing without tags
    func timing(_ name: String, duration: TimeInterval) async {
        await timing(name, duration: duration, tags: [:])
    }

    /// Convenience method for event without metadata
    func event(_ name: String) async {
        await event(name, metadata: nil)
    }

    /// Measure and record the duration of an async operation
    /// - Parameters:
    ///   - name: Metric name for the duration
    ///   - tags: Optional tags
    ///   - operation: The async operation to measure
    /// - Returns: The result of the operation
    func measure<T>(
        _ name: String,
        tags: [String: String] = [:],
        operation: () async throws -> T
    ) async throws -> T {
        let timer = startTimer()
        do {
            let result = try await operation()
            await timer.stop(metricName: name, tags: tags)
            return result
        } catch {
            var errorTags = tags
            errorTags["error"] = String(describing: error)
            await timer.stop(metricName: "\(name).error", tags: errorTags)
            throw error
        }
    }
}

// MARK: - No-Op Implementation

/// No-operation metrics client for when metrics are not needed
public struct NoOpMetricsClient: MetricsClient {

    public init() {}

    public func increment(_ name: String, tags: [String: String]) async {
        // No-op
    }

    public func gauge(_ name: String, value: Double, tags: [String: String]) async {
        // No-op
    }

    public func timing(_ name: String, duration: TimeInterval, tags: [String: String]) async {
        // No-op
    }

    public func startTimer() -> any MetricTimer {
        NoOpMetricTimer()
    }

    public func event(_ name: String, metadata: [String: Any]?) async {
        // No-op
    }

    public func flush() async {
        // No-op
    }
}

/// No-operation timer implementation
struct NoOpMetricTimer: MetricTimer {
    private let startTime = Date()

    func stop(metricName: String, tags: [String: String]) async {
        // No-op
    }

    var elapsedTime: TimeInterval {
        Date().timeIntervalSince(startTime)
    }
}

// MARK: - Console Metrics Client

/// Simple metrics client that logs to console for development/debugging
public actor ConsoleMetricsClient: MetricsClient {

    private let dateFormatter: DateFormatter
    private let enabled: Bool

    public init(enabled: Bool = true) {
        self.enabled = enabled
        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    }

    public func increment(_ name: String, tags: [String: String]) async {
        guard enabled else { return }
        let tagsStr = formatTags(tags)
        print("[METRIC] \(timestamp()) INCREMENT \(name)\(tagsStr)")
    }

    public func gauge(_ name: String, value: Double, tags: [String: String]) async {
        guard enabled else { return }
        let tagsStr = formatTags(tags)
        print("[METRIC] \(timestamp()) GAUGE \(name)=\(value)\(tagsStr)")
    }

    public func timing(_ name: String, duration: TimeInterval, tags: [String: String]) async {
        guard enabled else { return }
        let tagsStr = formatTags(tags)
        let ms = Int(duration * 1000)
        print("[METRIC] \(timestamp()) TIMING \(name)=\(ms)ms\(tagsStr)")
    }

    public nonisolated func startTimer() -> any MetricTimer {
        ConsoleMetricTimer(client: self)
    }

    public nonisolated func event(_ name: String, metadata: [String: Any]?) async {
        guard enabled else { return }
        let metaStr = metadata.map { " metadata=\($0)" } ?? ""
        print("[EVENT] \(await timestamp()) \(name)\(metaStr)")
    }

    public func flush() async {
        // No buffering, so nothing to flush
    }

    private func timestamp() -> String {
        dateFormatter.string(from: Date())
    }

    private func formatTags(_ tags: [String: String]) -> String {
        guard !tags.isEmpty else { return "" }
        let pairs = tags.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        return " tags=[\(pairs)]"
    }
}

/// Console timer implementation
struct ConsoleMetricTimer: MetricTimer {
    private let startTime = Date()
    private let client: ConsoleMetricsClient

    init(client: ConsoleMetricsClient) {
        self.client = client
    }

    func stop(metricName: String, tags: [String: String]) async {
        await client.timing(metricName, duration: elapsedTime, tags: tags)
    }

    var elapsedTime: TimeInterval {
        Date().timeIntervalSince(startTime)
    }
}

// MARK: - Metrics Constants

/// Standard metric names used throughout the Cashu implementation
public enum CashuMetrics {

    // MARK: - Wallet Metrics

    /// Wallet initialization metrics
    public static let walletInitializeStart = "cashu.wallet.initialize.start"
    public static let walletInitializeSuccess = "cashu.wallet.initialize.success"
    public static let walletInitializeFailure = "cashu.wallet.initialize.failure"
    public static let walletInitializeDuration = "cashu.wallet.initialize.duration"

    /// Mint operation metrics
    public static let mintStart = "cashu.mint.start"
    public static let mintSuccess = "cashu.mint.success"
    public static let mintFailure = "cashu.mint.failure"
    public static let mintDuration = "cashu.mint.duration"
    public static let mintAmount = "cashu.mint.amount"

    /// Melt operation metrics
    public static let meltStart = "cashu.melt.start"
    public static let meltSuccess = "cashu.melt.success"
    public static let meltFailure = "cashu.melt.failure"
    public static let meltFinalized = "cashu.melt.finalized"
    public static let meltRolledBack = "cashu.melt.rolled_back"
    public static let meltDuration = "cashu.melt.duration"
    public static let meltAmount = "cashu.melt.amount"
    public static let meltFees = "cashu.melt.fees"

    /// Swap operation metrics
    public static let swapStart = "cashu.swap.start"
    public static let swapSuccess = "cashu.swap.success"
    public static let swapFailure = "cashu.swap.failure"
    public static let swapDuration = "cashu.swap.duration"

    /// Balance and proof metrics
    public static let walletBalance = "cashu.wallet.balance"
    public static let proofCount = "cashu.wallet.proof_count"
    public static let proofVerification = "cashu.proof.verification"

    // MARK: - Network Metrics

    /// HTTP request metrics
    public static let httpRequestStart = "cashu.http.request.start"
    public static let httpRequestSuccess = "cashu.http.request.success"
    public static let httpRequestFailure = "cashu.http.request.failure"
    public static let httpRequestDuration = "cashu.http.request.duration"
    public static let httpRequestRetry = "cashu.http.request.retry"

    /// WebSocket metrics
    public static let wsConnect = "cashu.websocket.connect"
    public static let wsDisconnect = "cashu.websocket.disconnect"
    public static let wsReconnect = "cashu.websocket.reconnect"
    public static let wsMessageSent = "cashu.websocket.message.sent"
    public static let wsMessageReceived = "cashu.websocket.message.received"
    public static let wsHeartbeat = "cashu.websocket.heartbeat"

    // MARK: - Security Metrics

    /// Key generation and derivation
    public static let keyGeneration = "cashu.security.key_generation"
    public static let keyDerivation = "cashu.security.key_derivation"

    /// Encryption and signing
    public static let encryptionOperation = "cashu.security.encryption"
    public static let decryptionOperation = "cashu.security.decryption"
    public static let signingOperation = "cashu.security.signing"
    public static let verificationOperation = "cashu.security.verification"

    // MARK: - Storage Metrics

    /// Secure storage operations
    public static let storageRead = "cashu.storage.read"
    public static let storageWrite = "cashu.storage.write"
    public static let storageDelete = "cashu.storage.delete"
    public static let storageError = "cashu.storage.error"

    // MARK: - Protocol Specific Metrics (NUTs)

    /// NUT-00: Cryptography
    public static let blindingOperation = "cashu.nut00.blinding"
    public static let unblindingOperation = "cashu.nut00.unblinding"

    /// NUT-07: Token state check
    public static let tokenStateCheck = "cashu.nut07.state_check"

    /// NUT-08: Lightning fee return
    public static let lightningFeeReturn = "cashu.nut08.fee_return"

    /// NUT-10: P2PK
    public static let p2pkLock = "cashu.nut10.p2pk.lock"
    public static let p2pkUnlock = "cashu.nut10.p2pk.unlock"

    /// NUT-11: P2SH
    public static let p2shLock = "cashu.nut11.p2sh.lock"
    public static let p2shUnlock = "cashu.nut11.p2sh.unlock"

    /// NUT-14: HTLC
    public static let htlcLock = "cashu.nut14.htlc.lock"
    public static let htlcUnlock = "cashu.nut14.htlc.unlock"

    /// NUT-15: MPP
    public static let mppSplit = "cashu.nut15.mpp.split"
    public static let mppCombine = "cashu.nut15.mpp.combine"

    /// NUT-17: WebSockets
    public static let wsSubscription = "cashu.nut17.subscription"
    public static let wsNotification = "cashu.nut17.notification"
}
