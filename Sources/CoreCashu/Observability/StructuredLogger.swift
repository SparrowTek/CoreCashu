import Foundation

/// Enhanced structured logger with JSON output and secret redaction
/// Suitable for production environments and log aggregation systems
public final class StructuredLogger: LoggerProtocol, @unchecked Sendable {

    public var minimumLevel: LogLevel

    /// Output format for structured logs
    public enum OutputFormat: Sendable {
        case json           // Standard JSON format
        case jsonLines      // JSON Lines format (one JSON object per line)
        case logfmt         // Logfmt key=value format
    }

    /// Output destination
    public enum OutputDestination: Sendable {
        case stdout
        case stderr
        case file(URL)
        case custom(@Sendable (String) -> Void)
    }

    private let outputFormat: OutputFormat
    private let destination: OutputDestination
    private let encoder: JSONEncoder
    private let redactor: any SecretRedactor
    private let enableRedaction: Bool
    private let includeStackTrace: Bool
    private let applicationName: String
    private let environment: String?
    private let hostname: String

    /// Additional static metadata to include in all logs
    private let staticMetadata: [String: Any]

    /// Queue for thread-safe logging
    private let logQueue = DispatchQueue(label: "com.cashu.structuredlogger", attributes: .concurrent)

    public init(
        minimumLevel: LogLevel = .info,
        outputFormat: OutputFormat = .jsonLines,
        destination: OutputDestination = .stdout,
        enableRedaction: Bool = true,
        includeStackTrace: Bool = false,
        applicationName: String = "CoreCashu",
        environment: String? = nil,
        staticMetadata: [String: Any] = [:],
        redactor: (any SecretRedactor)? = nil
    ) {
        self.minimumLevel = minimumLevel
        self.outputFormat = outputFormat
        self.destination = destination
        self.enableRedaction = enableRedaction
        self.includeStackTrace = includeStackTrace
        self.applicationName = applicationName
        self.environment = environment
        self.staticMetadata = staticMetadata
        self.redactor = redactor ?? DefaultSecretRedactor()

        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = outputFormat == .json ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601

        // Get hostname
        self.hostname = ProcessInfo.processInfo.hostName
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

        let logEntry = createLogEntry(
            level: level,
            message: message,
            metadata: metadata,
            file: file,
            function: function,
            line: line
        )
        let formattedLog = formatLogEntry(logEntry)

        logQueue.async(flags: .barrier) {
            self.writeLog(formattedLog)
        }
    }

    private func createLogEntry(
        level: LogLevel,
        message: String,
        metadata: [String: Any]?,
        file: String,
        function: String,
        line: UInt
    ) -> [String: Any] {
        let timestamp = Date()
        let filename = (file as NSString).lastPathComponent

        // Redact sensitive information
        let finalMessage = enableRedaction ? redactor.redact(message) : message
        let finalMetadata = enableRedaction && metadata != nil ? redactor.redactMetadata(metadata!) : metadata

        var entry: [String: Any] = [
            "@timestamp": formatISO8601Date(timestamp),
            "timestamp_unix": timestamp.timeIntervalSince1970,
            "level": level.name.lowercased(),
            "level_value": level.rawValue,
            "message": finalMessage,
            "logger": applicationName,
            "hostname": hostname,
            "source": [
                "file": filename,
                "function": function,
                "line": Int(line)
            ]
        ]

        // Add environment if specified
        if let environment = environment {
            entry["environment"] = environment
        }

        // Add process information
        entry["process"] = [
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "name": ProcessInfo.processInfo.processName
        ]

        // Add thread information
        entry["thread"] = [
            "id": Thread.current.description,
            "is_main": Thread.isMainThread
        ]

        // Merge static metadata
        for (key, value) in staticMetadata {
            if entry[key] == nil {
                entry[key] = makeJSONSafe(value)
            }
        }

        // Add dynamic metadata
        if let metadata = finalMetadata {
            entry["metadata"] = makeJSONSafe(metadata)
        }

        // Add stack trace for errors if enabled
        if includeStackTrace && level >= .error {
            entry["stack_trace"] = Thread.callStackSymbols
        }

        return entry
    }

    private func formatLogEntry(_ entry: [String: Any]) -> String {
        switch outputFormat {
        case .json, .jsonLines:
            do {
                let data = try JSONSerialization.data(withJSONObject: entry, options: outputFormat == .json ? [.prettyPrinted, .sortedKeys] : [.sortedKeys])
                return String(data: data, encoding: .utf8) ?? "{}"
            } catch {
                return "{\"error\": \"Failed to serialize log entry\"}"
            }

        case .logfmt:
            return formatLogfmt(entry)
        }
    }

    private func formatLogfmt(_ entry: [String: Any]) -> String {
        var components: [String] = []

        for (key, value) in entry.sorted(by: { $0.key < $1.key }) {
            let formattedValue = formatLogfmtValue(value)
            components.append("\(key)=\(formattedValue)")
        }

        return components.joined(separator: " ")
    }

    private func formatLogfmtValue(_ value: Any) -> String {
        if let stringValue = value as? String {
            // Quote strings that contain spaces
            if stringValue.contains(" ") || stringValue.contains("=") {
                return "\"\(stringValue.replacingOccurrences(of: "\"", with: "\\\""))\""
            }
            return stringValue
        } else if let dictValue = value as? [String: Any] {
            let json = try? JSONSerialization.data(withJSONObject: dictValue)
            let jsonString = json.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return "\"\(jsonString.replacingOccurrences(of: "\"", with: "\\\""))\""
        } else if let arrayValue = value as? [Any] {
            let json = try? JSONSerialization.data(withJSONObject: arrayValue)
            let jsonString = json.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            return "\"\(jsonString.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return String(describing: value)
    }

    private func makeJSONSafe(_ value: Any) -> Any {
        switch value {
        case let string as String:
            return string
        case let bool as Bool:
            return bool
        case let int as Int:
            return int
        case let int8 as Int8:
            return Int(int8)
        case let int16 as Int16:
            return Int(int16)
        case let int32 as Int32:
            return Int(int32)
        case let int64 as Int64:
            return int64
        case let uint as UInt:
            return uint <= UInt(Int.max) ? Int(uint) : String(uint)
        case let uint8 as UInt8:
            return Int(uint8)
        case let uint16 as UInt16:
            return Int(uint16)
        case let uint32 as UInt32:
            return uint32
        case let uint64 as UInt64:
            return uint64 <= UInt64(Int.max) ? Int(uint64) : String(uint64)
        case let double as Double:
            return double
        case let float as Float:
            return Double(float)
        case let number as NSNumber:
            return number
        case let date as Date:
            return formatISO8601Date(date)
        case let url as URL:
            return url.absoluteString
        case let array as [Any]:
            return array.map { makeJSONSafe($0) }
        case let dictionary as [String: Any]:
            var sanitized: [String: Any] = [:]
            for (key, nestedValue) in dictionary {
                sanitized[key] = makeJSONSafe(nestedValue)
            }
            return sanitized
        default:
            return String(describing: value)
        }
    }

    private func writeLog(_ log: String) {
        switch destination {
        case .stdout:
            print(log)

        case .stderr:
            fputs(log + "\n", stderr)

        case .file(let url):
            do {
                let data = (log + "\n").data(using: .utf8) ?? Data()
                if FileManager.default.fileExists(atPath: url.path) {
                    let fileHandle = try FileHandle(forWritingTo: url)
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                } else {
                    try data.write(to: url)
                }
            } catch {
                // Fallback to stderr if file writing fails
                fputs("Failed to write log to file: \(error)\n", stderr)
                fputs(log + "\n", stderr)
            }

        case .custom(let handler):
            handler(log)
        }
    }
}

// MARK: - Date Formatting

private func formatISO8601Date(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: date)
}
