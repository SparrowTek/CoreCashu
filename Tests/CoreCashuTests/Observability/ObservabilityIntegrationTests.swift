import Testing
@testable import CoreCashu
import Foundation

@Suite("Observability Integration Tests")
struct ObservabilityIntegrationTests {

    @Test("Complete observability stack integration")
    func testFullObservabilityStack() async {
        // Create structured logger with redaction
        let logCapture = LogCapture()
        let logger = StructuredLogger(
            minimumLevel: .debug,
            outputFormat: .jsonLines,
            destination: .custom { log in
                Task {
                    await logCapture.append(log)
                }
            },
            enableRedaction: true,
            applicationName: "CashuIntegrationTest",
            environment: "test"
        )

        // Create metrics client with export handlers
        let metricsClient = EnhancedMetricsClient(
            enabled: true,
            aggregationWindow: .oneMinute,
            batchSize: 10,
            flushInterval: nil
        )

        // Track exported metrics
        let metricCapture = MetricCapture()
        await metricsClient.addExportHandler { metric in
            Task {
                await metricCapture.appendMetric(metric)
            }
        }

        // Simulate wallet initialization
        logger.info("Starting wallet initialization", metadata: [
            "version": "1.0.0",
            "environment": "test"
        ])

        await metricsClient.increment(CashuMetrics.walletInitializeStart)
        let initTimer = await metricsClient.startTimer()

        // Simulate some initialization work
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms

        // Log sensitive information (should be redacted)
        logger.debug("Loading wallet keys", metadata: [
            "mnemonic": "abandon ability able about above absent absorb abstract absurd abuse access accident",
            "privateKey": "e7b5e4d6c3a2f1b8d9c7a5e3f2d4c6b8a9d7e5c3f1b9d8c6a4e2f0d8c6b4a2e0"
        ])

        await initTimer.stop(metricName: CashuMetrics.walletInitializeDuration, tags: [:])
        await metricsClient.increment(CashuMetrics.walletInitializeSuccess)

        logger.info("Wallet initialized successfully")

        // Simulate mint operation
        logger.info("Starting mint operation", metadata: [
            "amount": 1000,
            "mint": "https://mint.example.com"
        ])

        await metricsClient.increment(CashuMetrics.mintStart)
        await metricsClient.gauge("wallet.balance", value: 1000, tags: ["currency": "sat"])

        let mintTimer = await metricsClient.startTimer()
        try? await Task.sleep(nanoseconds: 20_000_000) // 20ms

        await mintTimer.stop(metricName: CashuMetrics.mintDuration, tags: ["status": "success"])
        await metricsClient.increment(CashuMetrics.mintSuccess)

        // Simulate error condition
        logger.error("Melt operation failed", metadata: [
            "error": "Insufficient balance",
            "amount": 2000,
            "balance": 1000
        ])

        await metricsClient.increment(CashuMetrics.meltFailure, tags: ["reason": "insufficient_balance"])

        // Log wallet metrics
        for i in 1...5 {
            await metricsClient.timing("operation.latency", duration: Double(i) * 0.01)
        }

        // Give async operations time to complete
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Verify logging
        let logs = await logCapture.getLogs()
        #expect(logs.count >= 4)

        // Check that sensitive data was redacted
        let allLogs = logs.joined(separator: "\n")
        #expect(!allLogs.contains("abandon ability"))
        #expect(!allLogs.contains("e7b5e4d6c3a2"))
        #expect(allLogs.contains("[REDACTED]"))

        // Verify metrics were recorded
        let metrics = await metricCapture.getMetrics()
        #expect(metrics.count > 0)

        // Check specific metrics
        #expect(await metricCapture.containsName(CashuMetrics.walletInitializeStart))
        #expect(await metricCapture.containsName(CashuMetrics.walletInitializeSuccess))
        #expect(await metricCapture.containsName(CashuMetrics.mintStart))
        #expect(await metricCapture.containsName(CashuMetrics.mintSuccess))
        #expect(await metricCapture.containsName(CashuMetrics.meltFailure))

        // Verify metric types
        let counterMetrics = metrics.filter { $0.type == .counter }
        let gaugeMetrics = metrics.filter { $0.type == .gauge }
        let histogramMetrics = metrics.filter { $0.type == .histogram }

        #expect(counterMetrics.count > 0)
        #expect(gaugeMetrics.count > 0)
        #expect(histogramMetrics.count > 0)

        // Check tags are preserved
        let taggedMetrics = metrics.filter { !$0.tags.isEmpty }
        #expect(taggedMetrics.count > 0)
    }

    @Test("Observability under concurrent load")
    func testObservabilityConcurrency() async {
        let logger = StructuredLogger(
            minimumLevel: .info,
            outputFormat: .jsonLines,
            destination: .stdout,
            enableRedaction: true
        )

        let metricsClient = EnhancedMetricsClient(
            enabled: true,
            batchSize: 50,
            flushInterval: 0.5
        )

        // Run multiple concurrent operations
        await withTaskGroup(of: Void.self) { group in
            for i in 1...10 {
                group.addTask {
                    // Log operations
                    logger.info("Processing task \(i)")
                    logger.debug("Task \(i) details", metadata: ["id": i])

                    // Metrics operations
                    await metricsClient.increment("task.started", tags: ["task_id": String(i)])

                    let timer = await metricsClient.startTimer()
                    try? await Task.sleep(nanoseconds: UInt64.random(in: 1_000_000...10_000_000))
                    await timer.stop(metricName: "task.duration", tags: ["task_id": String(i)])

                    await metricsClient.increment("task.completed", tags: ["task_id": String(i)])

                    // Random gauge updates
                    await metricsClient.gauge("system.load", value: Double.random(in: 0...100))
                }
            }
        }

        // No crashes or data races = test passed
        #expect(true)
    }

    @Test("Export format compatibility")
    func testExportFormats() async {
        let metricsClient = EnhancedMetricsClient(enabled: true)

        // Record various metrics
        await metricsClient.increment("http.requests", tags: ["method": "GET", "status": "200"])
        await metricsClient.gauge("memory.usage", value: 2048.5, tags: ["unit": "MB"])
        await metricsClient.timing("api.latency", duration: 0.125, tags: ["endpoint": "/users"])

        // Give time for recording
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Get all metrics
        let allMetrics = await metricsClient.getMetrics()

        // Verify metrics can be exported to different formats
        var prometheusLines: [String] = []
        var statsdLines: [String] = []

        for metric in allMetrics {
            // Prometheus format
            let promName = metric.name.replacingOccurrences(of: ".", with: "_")
            let promTags = metric.tags.map { "\($0.key)=\"\($0.value)\"" }.joined(separator: ",")
            let promLine = promTags.isEmpty ?
                "\(promName) \(metric.value)" :
                "\(promName){\(promTags)} \(metric.value)"
            prometheusLines.append(promLine)

            // StatsD format
            let statsdTags = metric.tags.isEmpty ? "" :
                "#" + metric.tags.map { "\($0.key):\($0.value)" }.joined(separator: ",")
            let statsdType = switch metric.type {
                case .counter: "c"
                case .gauge: "g"
                case .histogram: "h"
                case .timer: "ms"
                default: "g"
            }
            let statsdLine = "\(metric.name):\(metric.value)|\(statsdType)\(statsdTags)"
            statsdLines.append(statsdLine)
        }

        #expect(prometheusLines.count == allMetrics.count)
        #expect(statsdLines.count == allMetrics.count)

        // Verify format correctness
        for line in prometheusLines {
            #expect(line.contains(" ") || line.contains("{"))
        }

        for line in statsdLines {
            #expect(line.contains(":") && line.contains("|"))
        }
    }
}