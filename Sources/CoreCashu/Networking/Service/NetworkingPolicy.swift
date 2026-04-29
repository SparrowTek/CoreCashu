import Foundation

/// Configuration describing retry behaviour for HTTP operations.
public struct HTTPRetryPolicy: Sendable {
    public let maxAttempts: Int
    public let baseDelay: TimeInterval
    public let jitter: TimeInterval
    public let retryableStatusCodes: Set<StatusCode>
    public let retryableURLErrorCodes: Set<URLError.Code>

    public init(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 0.2,
        jitter: TimeInterval = 0.05,
        retryableStatusCodes: Set<StatusCode> = [
            .requestTimeout,
            .tooManyRequests,
            .internalServerError,
            .badGateway,
            .serviceUnavailable,
            .gatewayTimeout
        ],
        retryableURLErrorCodes: Set<URLError.Code> = [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .dnsLookupFailed,
            .notConnectedToInternet
        ]
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.jitter = jitter
        self.retryableStatusCodes = retryableStatusCodes
        self.retryableURLErrorCodes = retryableURLErrorCodes
    }

    public static let `default` = HTTPRetryPolicy()
}

/// Aggregate configuration driving networking resilience features.
public struct NetworkingPolicy: Sendable {
    public let retryPolicy: HTTPRetryPolicy
    public let rateLimit: RateLimitConfiguration
    public let circuitBreaker: CircuitBreakerConfiguration

    public init(
        retryPolicy: HTTPRetryPolicy = .default,
        rateLimit: RateLimitConfiguration = .default,
        circuitBreaker: CircuitBreakerConfiguration = .default
    ) {
        self.retryPolicy = retryPolicy
        self.rateLimit = rateLimit
        self.circuitBreaker = circuitBreaker
    }

    public static let `default` = NetworkingPolicy()

    /// Convenience policy used by tests to avoid sleeping between retries.
    public static let immediateRetrying = NetworkingPolicy(
        retryPolicy: HTTPRetryPolicy(baseDelay: 0, jitter: 0)
    )

    /// Test-only policy that disables retry waits and pushes the rate limiter and circuit breaker
    /// out of the way. The shared `CashuEnvironment.current.routerDelegate` is a process-wide
    /// singleton, so when integration-test suites run concurrently they easily exhaust the
    /// production rate-limit (60 req / 60 s) within the suite's first wallet's `initialize()`.
    public static let testPermissive = NetworkingPolicy(
        retryPolicy: HTTPRetryPolicy(baseDelay: 0, jitter: 0),
        rateLimit: RateLimitConfiguration(maxRequests: 100_000, timeWindow: 60.0, burstCapacity: 100_000),
        circuitBreaker: CircuitBreakerConfiguration(failureThreshold: Int.max, openTimeout: 0.001, halfOpenMaxAttempts: Int.max)
    )
}
