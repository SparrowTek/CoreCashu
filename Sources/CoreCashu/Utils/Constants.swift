//
//  Constants.swift
//  CoreCashu
//
//  Centralized constants for magic numbers and configuration defaults.
//

import Foundation

// MARK: - Network Constants

/// Constants for network operations
public enum NetworkConstants {
    /// Default timeout interval for HTTP requests in seconds
    public static let defaultRequestTimeout: TimeInterval = 10.0
    
    /// Default timeout for connection establishment
    public static let connectionTimeout: TimeInterval = 30.0
}

// MARK: - WebSocket Constants

/// Constants for WebSocket operations
public enum WebSocketConstants {
    /// Default heartbeat/ping interval in seconds
    public static let heartbeatInterval: TimeInterval = 30
    
    /// Default connection timeout in seconds
    public static let connectionTimeout: TimeInterval = 30
    
    /// Default maximum number of consecutive heartbeat failures before reconnecting
    public static let maxHeartbeatFailures: Int = 3
    
    /// Message queue retry delay in nanoseconds (0.1 seconds)
    public static let messageQueueRetryDelayNanoseconds: UInt64 = 100_000_000
}

// MARK: - Reconnection Strategy Constants

/// Constants for reconnection strategies
public enum ReconnectionConstants {
    /// Default initial delay for exponential backoff in seconds
    public static let defaultInitialDelay: TimeInterval = 1.0
    
    /// Default maximum delay for exponential backoff in seconds
    public static let defaultMaxDelay: TimeInterval = 60.0
    
    /// Default multiplier for exponential backoff
    public static let defaultMultiplier: Double = 2.0
    
    /// Default maximum reconnection attempts (0 for unlimited)
    public static let defaultMaxAttempts: Int = 0
    
    /// Default jitter factor (0.0 to 1.0)
    public static let defaultJitterFactor: Double = 0.2
    
    /// Fixed interval strategy default interval in seconds
    public static let fixedInterval: TimeInterval = 5.0
    
    /// Fixed interval strategy default max attempts
    public static let fixedMaxAttempts: Int = 10
    
    /// Non-retryable WebSocket close codes (protocol error, unsupported data, policy violation)
    public static let nonRetryableCloseCodes: Set<Int> = [1002, 1003, 1008]
}

// MARK: - Rate Limiting Constants

/// Constants for rate limiting
public enum RateLimitConstants {
    /// Default maximum requests per time window
    public static let defaultMaxRequests: Int = 60
    
    /// Default time window in seconds
    public static let defaultTimeWindow: TimeInterval = 60.0
    
    /// Default burst capacity
    public static let defaultBurstCapacity: Int = 10
    
    /// Strict rate limit - maximum requests
    public static let strictMaxRequests: Int = 30
    
    /// Strict rate limit - burst capacity
    public static let strictBurstCapacity: Int = 5
    
    /// Relaxed rate limit - maximum requests
    public static let relaxedMaxRequests: Int = 120
    
    /// Relaxed rate limit - burst capacity
    public static let relaxedBurstCapacity: Int = 20
    
    /// Minimum wait time in seconds when rate limited
    public static let minimumWaitTime: TimeInterval = 0.1
}

// MARK: - Cryptographic Constants

/// Constants for cryptographic operations
public enum CryptoConstants {
    /// Default PBKDF2 iteration rounds for key derivation
    public static let pbkdfRounds: Int = 200_000
    
    /// AES-GCM authentication tag length in bytes
    public static let gcmTagLength: Int = 16
    
    /// AES key length in bytes (256-bit)
    public static let aesKeyLength: Int = 32
    
    /// GCM nonce/IV length in bytes
    public static let gcmNonceLength: Int = 12
    
    /// Salt length for key derivation in bytes
    public static let saltLength: Int = 32
    
    /// Secure overwrite filler size in bytes
    public static let secureOverwriteSize: Int = 1024
}

// MARK: - File System Constants

/// Constants for file system operations
public enum FileSystemConstants {
    /// Default directory permissions (owner read/write/execute)
    public static let directoryPermissions: Int = 0o700
    
    /// Default file permissions (owner read/write)
    public static let filePermissions: Int = 0o600
}

// MARK: - Wallet Restoration Constants

/// Constants for wallet restoration operations
public enum RestorationConstants {
    /// Default batch size for restoration
    public static let defaultBatchSize: Int = 100
    
    /// Maximum consecutive empty batches before stopping restoration
    public static let maxEmptyBatches: Int = 3
}

// MARK: - Time Conversion Helpers

/// Helper for time unit conversions
public enum TimeConversion {
    /// Convert seconds to nanoseconds
    public static func secondsToNanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(seconds * 1_000_000_000)
    }
    
    /// Nanoseconds per second
    public static let nanosecondsPerSecond: Double = 1_000_000_000
}
