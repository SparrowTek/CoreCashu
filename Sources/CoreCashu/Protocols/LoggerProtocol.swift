import Foundation

/// Protocol for logging operations in Cashu
/// Implementations can use os.log (Apple), print (console), or external logging frameworks
public protocol LoggerProtocol: Sendable {
    
    /// The minimum log level that will be recorded
    var minimumLevel: LogLevel { get set }
    
    /// Log a debug message
    /// - Parameters:
    ///   - message: The message to log
    ///   - metadata: Additional context as key-value pairs
    ///   - file: The file where the log was called
    ///   - function: The function where the log was called
    ///   - line: The line number where the log was called
    func debug(
        _ message: @autoclosure () -> String,
        metadata: [String: Any]?,
        file: String,
        function: String,
        line: UInt
    )
    
    /// Log an info message
    /// - Parameters:
    ///   - message: The message to log
    ///   - metadata: Additional context as key-value pairs
    ///   - file: The file where the log was called
    ///   - function: The function where the log was called
    ///   - line: The line number where the log was called
    func info(
        _ message: @autoclosure () -> String,
        metadata: [String: Any]?,
        file: String,
        function: String,
        line: UInt
    )
    
    /// Log a warning message
    /// - Parameters:
    ///   - message: The message to log
    ///   - metadata: Additional context as key-value pairs
    ///   - file: The file where the log was called
    ///   - function: The function where the log was called
    ///   - line: The line number where the log was called
    func warning(
        _ message: @autoclosure () -> String,
        metadata: [String: Any]?,
        file: String,
        function: String,
        line: UInt
    )
    
    /// Log an error message
    /// - Parameters:
    ///   - message: The message to log
    ///   - metadata: Additional context as key-value pairs
    ///   - file: The file where the log was called
    ///   - function: The function where the log was called
    ///   - line: The line number where the log was called
    func error(
        _ message: @autoclosure () -> String,
        metadata: [String: Any]?,
        file: String,
        function: String,
        line: UInt
    )
    
    /// Log a critical/fatal message
    /// - Parameters:
    ///   - message: The message to log
    ///   - metadata: Additional context as key-value pairs
    ///   - file: The file where the log was called
    ///   - function: The function where the log was called
    ///   - line: The line number where the log was called
    func critical(
        _ message: @autoclosure () -> String,
        metadata: [String: Any]?,
        file: String,
        function: String,
        line: UInt
    )
}

/// Log levels for filtering messages
public enum LogLevel: Int, Comparable, CaseIterable, Sendable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
    case critical = 4
    
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
    
    public var symbol: String {
        switch self {
        case .debug: return "🔍"
        case .info: return "ℹ️"
        case .warning: return "⚠️"
        case .error: return "❌"
        case .critical: return "🔥"
        }
    }
    
    public var name: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARNING"
        case .error: return "ERROR"
        case .critical: return "CRITICAL"
        }
    }
}

// MARK: - Default Implementations with Convenience Methods

public extension LoggerProtocol {
    
    /// Log a debug message with default parameters
    func debug(
        _ message: @autoclosure () -> String,
        metadata: [String: Any]? = nil,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        debug(message(), metadata: metadata, file: file, function: function, line: line)
    }
    
    /// Log an info message with default parameters
    func info(
        _ message: @autoclosure () -> String,
        metadata: [String: Any]? = nil,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        info(message(), metadata: metadata, file: file, function: function, line: line)
    }
    
    /// Log a warning message with default parameters
    func warning(
        _ message: @autoclosure () -> String,
        metadata: [String: Any]? = nil,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        warning(message(), metadata: metadata, file: file, function: function, line: line)
    }
    
    /// Log an error message with default parameters
    func error(
        _ message: @autoclosure () -> String,
        metadata: [String: Any]? = nil,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        error(message(), metadata: metadata, file: file, function: function, line: line)
    }
    
    /// Log a critical message with default parameters
    func critical(
        _ message: @autoclosure () -> String,
        metadata: [String: Any]? = nil,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        critical(message(), metadata: metadata, file: file, function: function, line: line)
    }
}

// MARK: - Logger Context

/// Context that can be attached to log messages
public struct LogContext: Sendable {
    public let mintURL: URL?
    public let walletID: String?
    public let operation: String?
    public let additionalData: [String: String]
    
    public init(
        mintURL: URL? = nil,
        walletID: String? = nil,
        operation: String? = nil,
        additionalData: [String: String] = [:]
    ) {
        self.mintURL = mintURL
        self.walletID = walletID
        self.operation = operation
        self.additionalData = additionalData
    }
    
    /// Convert context to metadata dictionary
    public var metadata: [String: Any] {
        var result: [String: Any] = additionalData
        if let mintURL = mintURL {
            result["mintURL"] = mintURL.absoluteString
        }
        if let walletID = walletID {
            result["walletID"] = walletID
        }
        if let operation = operation {
            result["operation"] = operation
        }
        return result
    }
}

// MARK: - No-Op Logger

/// A logger that does nothing, useful for testing or when logging is disabled
public struct NoOpLogger: LoggerProtocol {
    public var minimumLevel: LogLevel = .critical
    
    public init() {}
    
    public func debug(_ message: @autoclosure () -> String, metadata: [String: Any]?, file: String, function: String, line: UInt) {}
    public func info(_ message: @autoclosure () -> String, metadata: [String: Any]?, file: String, function: String, line: UInt) {}
    public func warning(_ message: @autoclosure () -> String, metadata: [String: Any]?, file: String, function: String, line: UInt) {}
    public func error(_ message: @autoclosure () -> String, metadata: [String: Any]?, file: String, function: String, line: UInt) {}
    public func critical(_ message: @autoclosure () -> String, metadata: [String: Any]?, file: String, function: String, line: UInt) {}
}