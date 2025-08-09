import Foundation

/// Console logger implementation that outputs to stdout/stderr
/// This is the default logger for CoreCashu when no platform-specific logger is provided
public struct ConsoleLogger: LoggerProtocol {
    
    public var minimumLevel: LogLevel
    
    /// Date formatter for log timestamps
    private let dateFormatter: DateFormatter
    
    /// Whether to include file/function/line information
    public let includeSourceLocation: Bool
    
    /// Whether to use colored output (ANSI escape codes)
    public let useColors: Bool
    
    /// Whether to output to stderr for errors/warnings
    public let useStderr: Bool
    
    public init(
        minimumLevel: LogLevel = .info,
        includeSourceLocation: Bool = true,
        useColors: Bool = false,
        useStderr: Bool = true
    ) {
        self.minimumLevel = minimumLevel
        self.includeSourceLocation = includeSourceLocation
        self.useColors = useColors
        self.useStderr = useStderr
        
        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        self.dateFormatter.timeZone = TimeZone.current
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
        
        let timestamp = dateFormatter.string(from: Date())
        let levelString = formatLevel(level)
        let sourceLocation = includeSourceLocation ? formatSourceLocation(file: file, function: function, line: line) : ""
        let metadataString = formatMetadata(metadata)
        
        let logMessage = "\(timestamp) \(levelString)\(sourceLocation) \(message)\(metadataString)"
        
        // Output to appropriate stream
        let outputMessage = useColors ? colorize(logMessage, level: level) : logMessage
        if useStderr && (level >= .warning) {
            fputs(outputMessage + "\n", stderr)
        } else {
            print(outputMessage)
        }
    }
    
    private func formatLevel(_ level: LogLevel) -> String {
        "[\(level.name)]"
    }
    
    private func formatSourceLocation(file: String, function: String, line: UInt) -> String {
        let filename = (file as NSString).lastPathComponent
        return " \(filename):\(line) \(function)"
    }
    
    private func formatMetadata(_ metadata: [String: Any]?) -> String {
        guard let metadata = metadata, !metadata.isEmpty else { return "" }
        
        let formattedPairs = metadata.map { key, value in
            "\(key)=\(value)"
        }.sorted()
        
        return " | \(formattedPairs.joined(separator: ", "))"
    }
    
    private func colorize(_ message: String, level: LogLevel) -> String {
        let colorCode: String
        switch level {
        case .debug:
            colorCode = "36" // Cyan
        case .info:
            colorCode = "32" // Green
        case .warning:
            colorCode = "33" // Yellow
        case .error:
            colorCode = "31" // Red
        case .critical:
            colorCode = "35" // Magenta
        }
        
        return "\u{001B}[0;\(colorCode)m\(message)\u{001B}[0m"
    }
}

// MARK: - Structured Console Logger

/// A more structured console logger that outputs JSON for machine processing
public struct StructuredConsoleLogger: LoggerProtocol {
    
    public var minimumLevel: LogLevel
    
    private let encoder: JSONEncoder
    
    public init(minimumLevel: LogLevel = .info) {
        self.minimumLevel = minimumLevel
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
    }
    
    public func debug(_ message: @autoclosure () -> String, metadata: [String: Any]?, file: String, function: String, line: UInt) {
        log(level: .debug, message(), metadata: metadata, file: file, function: function, line: line)
    }
    
    public func info(_ message: @autoclosure () -> String, metadata: [String: Any]?, file: String, function: String, line: UInt) {
        log(level: .info, message(), metadata: metadata, file: file, function: function, line: line)
    }
    
    public func warning(_ message: @autoclosure () -> String, metadata: [String: Any]?, file: String, function: String, line: UInt) {
        log(level: .warning, message(), metadata: metadata, file: file, function: function, line: line)
    }
    
    public func error(_ message: @autoclosure () -> String, metadata: [String: Any]?, file: String, function: String, line: UInt) {
        log(level: .error, message(), metadata: metadata, file: file, function: function, line: line)
    }
    
    public func critical(_ message: @autoclosure () -> String, metadata: [String: Any]?, file: String, function: String, line: UInt) {
        log(level: .critical, message(), metadata: metadata, file: file, function: function, line: line)
    }
    
    private func log(
        level: LogLevel,
        _ message: String,
        metadata: [String: Any]?,
        file: String,
        function: String,
        line: UInt
    ) {
        guard level >= minimumLevel else { return }
        
        var logEntry: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "level": level.name,
            "message": message,
            "file": (file as NSString).lastPathComponent,
            "function": function,
            "line": line
        ]
        
        if let metadata = metadata {
            logEntry["metadata"] = metadata
        }
        
        // Convert to JSON and output
        if let data = try? JSONSerialization.data(withJSONObject: logEntry, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            print(json)
        }
    }
}