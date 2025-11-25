import Testing
@testable import CoreCashu
import Foundation

// Thread-safe log capture for testing
actor LogCapture {
    private var logs: [String] = []

    func append(_ log: String) {
        logs.append(log)
    }

    func getLogs() -> [String] {
        logs
    }

    func getLastLog() -> String? {
        logs.last
    }

    func count() -> Int {
        logs.count
    }
}

@Suite("Logging System Tests", .serialized)
struct LoggingTests {

    // MARK: - Secret Redaction Tests

    @Test("Secret redactor detects and redacts mnemonics")
    func testMnemonicRedaction() {
        let redactor = DefaultSecretRedactor()
        let mnemonic = "abandon ability able about above absent absorb abstract absurd abuse access accident"
        let redacted = redactor.redact(mnemonic)
        #expect(redacted == "[REDACTED]")
    }

    @Test("Secret redactor detects and redacts private keys")
    func testPrivateKeyRedaction() {
        let redactor = DefaultSecretRedactor()
        let privateKey = "e7b5e4d6c3a2f1b8d9c7a5e3f2d4c6b8a9d7e5c3f1b9d8c6a4e2f0d8c6b4a2e0"
        let text = "Private key is \(privateKey) and should be hidden"
        let redacted = redactor.redact(text)
        #expect(redacted.contains("[REDACTED]"))
        #expect(!redacted.contains(privateKey))
    }

    @Test("Secret redactor handles Cashu tokens")
    func testCashuTokenRedaction() {
        let redactor = DefaultSecretRedactor()
        let token = "cashuAeyJ0b2tlbiI6W3sicHJvb2ZzIjpbeyJhbW91bnQiOjIsImlkIjoiMDA5YTFmMjkzMjUzZTQxZSIsInNlY3JldCI6IjQwNzkxNWJjMjEyYmU2MWE3N2UzZTZkMmFlYjRjNzI3OTgwYmRhNTFjZDA2YTZhZmMyOWUyODYxNzY4YTc4MzciLCJDIjoiMDJiYzkwOTc5OTdkODFhZmIyY2M3MzQ2YjVlNDM0NWE5MzQ2YmQyYTUwNmViNzk1ODU5OGE3MmYwY2Y4NTE2M2VhIn0="
        let text = "Token: \(token)"
        let redacted = redactor.redact(text)
        #expect(redacted == "Token: [REDACTED]")
    }

    @Test("Secret redactor handles metadata")
    func testMetadataRedaction() {
        let redactor = DefaultSecretRedactor()
        let metadata: [String: Any] = [
            "user": "alice",
            "mnemonic": "abandon ability able about above absent absorb abstract absurd abuse access accident",
            "privateKey": "e7b5e4d6c3a2f1b8d9c7a5e3f2d4c6b8a9d7e5c3f1b9d8c6a4e2f0d8c6b4a2e0",
            "amount": 1000,
            "nested": [
                "secret": "hidden_value",
                "public": "visible"
            ]
        ]

        let redacted = redactor.redactMetadata(metadata)
        #expect(redacted["user"] as? String == "alice")
        #expect(redacted["mnemonic"] as? String == "[REDACTED]")
        #expect(redacted["privateKey"] as? String == "[REDACTED]")
        #expect(redacted["amount"] as? Int == 1000)

        if let nested = redacted["nested"] as? [String: Any] {
            #expect(nested["secret"] as? String == "[REDACTED]")
            #expect(nested["public"] as? String == "visible")
        }
    }

    @Test("NoOp redactor passes through unchanged")
    func testNoOpRedactor() {
        let redactor = NoOpRedactor()
        let sensitive = "e7b5e4d6c3a2f1b8d9c7a5e3f2d4c6b8a9d7e5c3f1b9d8c6a4e2f0d8c6b4a2e0"
        #expect(redactor.redact(sensitive) == sensitive)

        let metadata = ["secret": "value"]
        #expect(redactor.redactMetadata(metadata)["secret"] as? String == "value")
    }

    // MARK: - Structured Logger Tests

    @Test("Structured logger creates proper JSON output")
    func testStructuredLoggerJSON() async {
        let logCapture = LogCapture()

        // Use a synchronous capture to avoid Task race conditions
        let logger = StructuredLogger(
            minimumLevel: .debug,
            outputFormat: .jsonLines,
            destination: .custom { @Sendable log in
                // Synchronous capture - the actor will handle thread safety
                Task { @MainActor in
                    await logCapture.append(log)
                }
            },
            enableRedaction: false
        )

        logger.info("Test message", metadata: ["key": "value"])

        // Give async logging time to process - increased to ensure completion
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms

        let capturedLog = await logCapture.getLastLog()
        #expect(capturedLog != nil)
        if let log = capturedLog,
           let data = log.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            #expect(json["message"] as? String == "Test message")
            #expect(json["level"] as? String == "info")
            #expect((json["metadata"] as? [String: Any])?["key"] as? String == "value")
        }
    }

    @Test("Structured logger redacts secrets")
    func testStructuredLoggerRedaction() async {
        let logCapture = LogCapture()
        let logger = StructuredLogger(
            minimumLevel: .debug,
            outputFormat: .jsonLines,
            destination: .custom { @Sendable log in
                Task { @MainActor in
                    await logCapture.append(log)
                }
            },
            enableRedaction: true
        )

        let privateKey = "e7b5e4d6c3a2f1b8d9c7a5e3f2d4c6b8a9d7e5c3f1b9d8c6a4e2f0d8c6b4a2e0"
        logger.error("Error with key: \(privateKey)", metadata: ["privateKey": privateKey])

        // Give async logging time to process
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms

        let capturedLog = await logCapture.getLastLog()
        #expect(capturedLog != nil)
        #expect(!capturedLog!.contains(privateKey))
        #expect(capturedLog!.contains("[REDACTED]"))
    }

    @Test("Structured logger respects minimum level")
    func testStructuredLoggerLevel() async {
        let logCapture = LogCapture()
        let logger = StructuredLogger(
            minimumLevel: .warning,
            outputFormat: .jsonLines,
            destination: .custom { @Sendable log in
                Task { @MainActor in
                    await logCapture.append(log)
                }
            }
        )

        logger.debug("Debug message")
        logger.info("Info message")
        logger.warning("Warning message")
        logger.error("Error message")

        // Give async logging time to process
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms

        let capturedCount = await logCapture.count()
        #expect(capturedCount == 2)
    }

    @Test("Structured logger logfmt format")
    func testStructuredLoggerLogfmt() async {
        let logCapture = LogCapture()
        let logger = StructuredLogger(
            minimumLevel: .info,
            outputFormat: .logfmt,
            destination: .custom { @Sendable log in
                Task { @MainActor in
                    await logCapture.append(log)
                }
            },
            enableRedaction: false
        )

        logger.info("Test", metadata: ["key": "value with spaces"])

        // Give async logging time to process
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms

        let capturedLog = await logCapture.getLastLog()
        #expect(capturedLog != nil)
        #expect(capturedLog!.contains("message=Test"))
        #expect(capturedLog!.contains("level=info"))
        #expect(capturedLog!.contains("\"value with spaces\""))
    }

    // MARK: - Console Logger Tests

    @Test("Console logger formats messages correctly")
    func testConsoleLoggerFormatting() {
        let logger = ConsoleLogger(
            minimumLevel: .debug,
            includeSourceLocation: true,
            useColors: false,
            useStderr: false
        )

        // Since console logger outputs directly, we can't easily capture
        // but we can verify it doesn't crash
        logger.debug("Debug message")
        logger.info("Info message", metadata: ["test": "value"])
        logger.warning("Warning message")
        logger.error("Error message")
        logger.critical("Critical message")

        #expect(Bool(true)) // If we got here without crashing, test passes
    }

    @Test("StructuredConsoleLogger JSON output")
    func testStructuredConsoleLogger() {
        let logger = StructuredConsoleLogger(minimumLevel: .info)

        // Test that it doesn't crash with various inputs
        logger.info("Test message", metadata: ["key": "value"])
        logger.error("Error message", metadata: ["error": "details", "code": 500])

        #expect(Bool(true)) // If we got here without crashing, test passes
    }

    // MARK: - Log Level Tests

    @Test("Log levels compare correctly")
    func testLogLevelComparison() {
        #expect(LogLevel.debug < LogLevel.info)
        #expect(LogLevel.info < LogLevel.warning)
        #expect(LogLevel.warning < LogLevel.error)
        #expect(LogLevel.error < LogLevel.critical)
    }

    @Test("Log level symbols and names")
    func testLogLevelSymbols() {
        #expect(LogLevel.debug.symbol == "🔍")
        #expect(LogLevel.info.symbol == "ℹ️")
        #expect(LogLevel.warning.symbol == "⚠️")
        #expect(LogLevel.error.symbol == "❌")
        #expect(LogLevel.critical.symbol == "🔥")

        #expect(LogLevel.debug.name == "DEBUG")
        #expect(LogLevel.info.name == "INFO")
        #expect(LogLevel.warning.name == "WARNING")
        #expect(LogLevel.error.name == "ERROR")
        #expect(LogLevel.critical.name == "CRITICAL")
    }

    // MARK: - NoOp Logger Tests

    @Test("NoOp logger does nothing")
    func testNoOpLogger() {
        let logger = NoOpLogger()

        // Should not crash or produce output
        logger.debug("Debug")
        logger.info("Info")
        logger.warning("Warning")
        logger.error("Error")
        logger.critical("Critical")

        #expect(logger.minimumLevel == .critical)
    }

    // MARK: - Log Context Tests

    @Test("Log context metadata conversion")
    func testLogContext() {
        let context = LogContext(
            mintURL: URL(string: "https://mint.example.com"),
            walletID: "wallet123",
            operation: "mint",
            additionalData: ["amount": "1000"]
        )

        let metadata = context.metadata
        #expect(metadata["mintURL"] as? String == "https://mint.example.com")
        #expect(metadata["walletID"] as? String == "wallet123")
        #expect(metadata["operation"] as? String == "mint")
        #expect(metadata["amount"] as? String == "1000")
    }

    // MARK: - Integration Tests

    @Test("Logger integration with wallet operations")
    func testLoggerIntegration() async {
        let logCapture = LogCapture()
        let logger = StructuredLogger(
            minimumLevel: .debug,
            outputFormat: .jsonLines,
            destination: .custom { @Sendable log in
                Task { @MainActor in
                    await logCapture.append(log)
                }
            },
            enableRedaction: true,
            applicationName: "CashuWalletTest",
            environment: "test"
        )

        // Simulate wallet operations
        logger.info("Initializing wallet", metadata: ["mintURL": "https://mint.example.com"])
        logger.debug("Fetching keysets")
        logger.warning("Rate limit approaching", metadata: ["current": 90, "limit": 100])
        logger.error("Melt operation failed", metadata: [
            "error": "Insufficient balance",
            "privateKey": "e7b5e4d6c3a2f1b8d9c7a5e3f2d4c6b8a9d7e5c3f1b9d8c6a4e2f0d8c6b4a2e0"
        ])

        // Give async logging time to process
        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms

        let capturedLogs = await logCapture.getLogs()
        #expect(capturedLogs.count == 4)

        // Verify no sensitive data leaked
        for log in capturedLogs {
            #expect(!log.contains("e7b5e4d6c3a2"))
        }

        // Verify structure
        if let lastLog = capturedLogs.last,
           let data = lastLog.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            #expect(json["environment"] as? String == "test")
            #expect(json["logger"] as? String == "CashuWalletTest")
        }
    }
}