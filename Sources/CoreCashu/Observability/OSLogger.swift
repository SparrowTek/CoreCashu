#if canImport(os)
import Foundation
import os.log

/// Apple platform logger using os.log framework
/// Provides structured logging with privacy controls and efficient performance
public final class OSLogger: LoggerProtocol, @unchecked Sendable {

    public var minimumLevel: LogLevel

    /// The subsystem for logging (typically bundle identifier)
    private let subsystem: String

    /// Category for organizing logs
    private let category: String

    /// OS Log instance
    private let osLog: OSLog

    /// Secret redactor for sensitive information
    private let redactor: any SecretRedactor

    /// Enable/disable secret redaction
    private let enableRedaction: Bool

    public init(
        subsystem: String = "com.cashu.core",
        category: String = "default",
        minimumLevel: LogLevel = .info,
        enableRedaction: Bool = true,
        redactor: (any SecretRedactor)? = nil
    ) {
        self.subsystem = subsystem
        self.category = category
        self.minimumLevel = minimumLevel
        self.enableRedaction = enableRedaction
        self.redactor = redactor ?? DefaultSecretRedactor()
        self.osLog = OSLog(subsystem: subsystem, category: category)
    }

    // MARK: - LoggerProtocol Implementation

    public func debug(
        _ message: @autoclosure () -> String,
        metadata: [String: Any]?,
        file: String,
        function: String,
        line: UInt
    ) {
        log(level: .debug, message(), metadata: metadata, file: file, function: function, line: line)
    }

    public func info(
        _ message: @autoclosure () -> String,
        metadata: [String: Any]?,
        file: String,
        function: String,
        line: UInt
    ) {
        log(level: .info, message(), metadata: metadata, file: file, function: function, line: line)
    }

    public func warning(
        _ message: @autoclosure () -> String,
        metadata: [String: Any]?,
        file: String,
        function: String,
        line: UInt
    ) {
        log(level: .warning, message(), metadata: metadata, file: file, function: function, line: line)
    }

    public func error(
        _ message: @autoclosure () -> String,
        metadata: [String: Any]?,
        file: String,
        function: String,
        line: UInt
    ) {
        log(level: .error, message(), metadata: metadata, file: file, function: function, line: line)
    }

    public func critical(
        _ message: @autoclosure () -> String,
        metadata: [String: Any]?,
        file: String,
        function: String,
        line: UInt
    ) {
        log(level: .critical, message(), metadata: metadata, file: file, function: function, line: line)
    }

    // MARK: - Private Methods

    private func log(
        level: LogLevel,
        _ message: String,
        metadata: [String: Any]?,
        file: String,
        function: String,
        line: UInt
    ) {
        guard level >= minimumLevel else { return }

        let osLogType = mapLogLevel(level)
        let redactedMessage = enableRedaction ? redactor.redact(message) : message
        let redactedMetadata = enableRedaction && metadata != nil ? redactor.redactMetadata(metadata!) : metadata

        // Format the log message with metadata
        let formattedMessage = formatMessage(
            redactedMessage,
            metadata: redactedMetadata,
            file: file,
            function: function,
            line: line
        )

        // Log using os_log with appropriate privacy settings
        os_log(
            "%{public}@",
            log: osLog,
            type: osLogType,
            formattedMessage as NSString
        )
    }

    private func mapLogLevel(_ level: LogLevel) -> OSLogType {
        switch level {
        case .debug:
            return .debug
        case .info:
            return .info
        case .warning:
            return .default
        case .error:
            return .error
        case .critical:
            return .fault
        }
    }

    private func formatMessage(
        _ message: String,
        metadata: [String: Any]?,
        file: String,
        function: String,
        line: UInt
    ) -> String {
        let filename = (file as NSString).lastPathComponent
        var components = ["\(filename):\(line)", function, message]

        if let metadata = metadata, !metadata.isEmpty {
            let metadataString = formatMetadata(metadata)
            components.append(metadataString)
        }

        return components.joined(separator: " | ")
    }

    private func formatMetadata(_ metadata: [String: Any]) -> String {
        let formattedPairs = metadata.map { key, value in
            "\(key)=\(formatValue(value))"
        }.sorted()

        return "[\(formattedPairs.joined(separator: ", "))]"
    }

    private func formatValue(_ value: Any) -> String {
        if let data = value as? Data {
            return data.base64EncodedString()
        } else if let array = value as? [Any] {
            return array.map { formatValue($0) }.description
        } else if let dict = value as? [String: Any] {
            return dict.mapValues { formatValue($0) }.description
        }
        return String(describing: value)
    }
}

// MARK: - Specialized Category Loggers

public extension OSLogger {

    /// Create a logger for network operations
    static func network(
        subsystem: String = "com.cashu.core",
        minimumLevel: LogLevel = .info,
        enableRedaction: Bool = true
    ) -> OSLogger {
        OSLogger(
            subsystem: subsystem,
            category: "network",
            minimumLevel: minimumLevel,
            enableRedaction: enableRedaction
        )
    }

    /// Create a logger for cryptographic operations
    static func crypto(
        subsystem: String = "com.cashu.core",
        minimumLevel: LogLevel = .warning,
        enableRedaction: Bool = true
    ) -> OSLogger {
        OSLogger(
            subsystem: subsystem,
            category: "crypto",
            minimumLevel: minimumLevel,
            enableRedaction: enableRedaction
        )
    }

    /// Create a logger for wallet operations
    static func wallet(
        subsystem: String = "com.cashu.core",
        minimumLevel: LogLevel = .info,
        enableRedaction: Bool = true
    ) -> OSLogger {
        OSLogger(
            subsystem: subsystem,
            category: "wallet",
            minimumLevel: minimumLevel,
            enableRedaction: enableRedaction
        )
    }

    /// Create a logger for storage operations
    static func storage(
        subsystem: String = "com.cashu.core",
        minimumLevel: LogLevel = .info,
        enableRedaction: Bool = true
    ) -> OSLogger {
        OSLogger(
            subsystem: subsystem,
            category: "storage",
            minimumLevel: minimumLevel,
            enableRedaction: enableRedaction
        )
    }
}

#endif
