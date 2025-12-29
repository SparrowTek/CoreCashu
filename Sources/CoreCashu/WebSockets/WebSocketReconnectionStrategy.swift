import Foundation

/// Strategy for WebSocket reconnection attempts
public protocol WebSocketReconnectionStrategy: Sendable {
    /// Calculate the delay before the next reconnection attempt
    /// - Parameters:
    ///   - attempt: The current attempt number (1-based)
    ///   - lastError: The error that caused the disconnection
    /// - Returns: The delay in seconds before attempting reconnection, or nil to stop retrying
    func delay(for attempt: Int, lastError: (any Error)?) async -> TimeInterval?

    /// Called when a reconnection attempt succeeds
    func reset() async

    /// Check if reconnection should be attempted
    /// - Parameter error: The error that caused disconnection
    /// - Returns: true if reconnection should be attempted
    func shouldReconnect(error: (any Error)?) async -> Bool
}

/// Exponential backoff reconnection strategy with jitter
public actor ExponentialBackoffStrategy: WebSocketReconnectionStrategy {

    /// Configuration for exponential backoff
    public struct Configuration: Sendable {
        /// Initial delay in seconds
        public let initialDelay: TimeInterval

        /// Maximum delay in seconds
        public let maxDelay: TimeInterval

        /// Base multiplier for exponential growth
        public let multiplier: Double

        /// Maximum number of attempts (0 for unlimited)
        public let maxAttempts: Int

        /// Jitter factor (0.0 to 1.0) to randomize delays
        public let jitterFactor: Double

        /// Errors that should not trigger reconnection
        public let nonRetryableErrors: Set<Int>

        public init(
            initialDelay: TimeInterval = ReconnectionConstants.defaultInitialDelay,
            maxDelay: TimeInterval = ReconnectionConstants.defaultMaxDelay,
            multiplier: Double = ReconnectionConstants.defaultMultiplier,
            maxAttempts: Int = ReconnectionConstants.defaultMaxAttempts,
            jitterFactor: Double = ReconnectionConstants.defaultJitterFactor,
            nonRetryableErrors: Set<Int> = ReconnectionConstants.nonRetryableCloseCodes
        ) {
            self.initialDelay = initialDelay
            self.maxDelay = maxDelay
            self.multiplier = multiplier
            self.maxAttempts = maxAttempts
            self.jitterFactor = max(0, min(1, jitterFactor))
            self.nonRetryableErrors = nonRetryableErrors
        }
    }

    private let configuration: Configuration
    private var currentAttempt: Int = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func delay(for attempt: Int, lastError: (any Error)?) async -> TimeInterval? {
        // Check max attempts
        if configuration.maxAttempts > 0 && attempt > configuration.maxAttempts {
            return nil
        }

        currentAttempt = attempt

        // Calculate base delay with exponential backoff
        let baseDelay = min(
            configuration.initialDelay * pow(configuration.multiplier, Double(attempt - 1)),
            configuration.maxDelay
        )

        // Add jitter to prevent thundering herd
        let jitterRange = baseDelay * configuration.jitterFactor
        let jitter = Double.random(in: -jitterRange...jitterRange)

        return max(0, baseDelay + jitter)
    }

    public func reset() async {
        currentAttempt = 0
    }

    public func shouldReconnect(error: (any Error)?) async -> Bool {
        // Check for non-retryable WebSocket close codes
        if let wsError = error as? WebSocketError,
           case .connectionClosed = wsError {
            return true
        }

        // Check for specific close codes
        if let closeCode = extractCloseCode(from: error),
           configuration.nonRetryableErrors.contains(closeCode) {
            return false
        }

        // Default to reconnecting for other errors
        return true
    }

    private func extractCloseCode(from error: (any Error)?) -> Int? {
        // Try to extract close code from various error types
        if let wsError = error as? WebSocketError {
            switch wsError {
            case .connectionFailed(let reason):
                // Parse close code from reason string if present
                if let range = reason.range(of: "code: ") {
                    let codeStr = String(reason[range.upperBound...].prefix(4))
                    let trimmed = codeStr.trimmingCharacters(in: .decimalDigits.inverted)
                    if let code = Int(trimmed) {
                        return code
                    }
                }
            default:
                break
            }
        }
        return nil
    }
}

/// Simple fixed-interval reconnection strategy
public actor FixedIntervalStrategy: WebSocketReconnectionStrategy {

    private let interval: TimeInterval
    private let maxAttempts: Int

    public init(interval: TimeInterval = ReconnectionConstants.fixedInterval, maxAttempts: Int = ReconnectionConstants.fixedMaxAttempts) {
        self.interval = interval
        self.maxAttempts = maxAttempts
    }

    public func delay(for attempt: Int, lastError: (any Error)?) async -> TimeInterval? {
        if maxAttempts > 0 && attempt > maxAttempts {
            return nil
        }
        return interval
    }

    public func reset() async {
        // No state to reset
    }

    public func shouldReconnect(error: (any Error)?) async -> Bool {
        true
    }
}

/// No reconnection strategy (single attempt only)
public struct NoReconnectionStrategy: WebSocketReconnectionStrategy {

    public init() {}

    public func delay(for attempt: Int, lastError: (any Error)?) async -> TimeInterval? {
        nil
    }

    public func reset() async {
        // No state to reset
    }

    public func shouldReconnect(error: (any Error)?) async -> Bool {
        false
    }
}
