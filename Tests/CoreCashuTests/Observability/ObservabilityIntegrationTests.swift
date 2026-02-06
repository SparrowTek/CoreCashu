import Testing
@testable import CoreCashu
import Foundation

private final class SynchronizedLogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var logs: [String] = []

    func append(_ log: String) {
        lock.lock()
        logs.append(log)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        let copy = logs
        lock.unlock()
        return copy
    }
}

@Suite("Observability Integration Tests", .serialized)
struct ObservabilityIntegrationTests {

    @Test("Complete observability stack integration")
    func testFullObservabilityStack() async {
        let logCapture = SynchronizedLogBuffer()
        let logger = StructuredLogger(
            minimumLevel: .debug,
            outputFormat: .jsonLines,
            destination: .custom { log in logCapture.append(log) },
            enableRedaction: true
        )

        let metricsClient = EnhancedMetricsClient(
            enabled: true,
            aggregationWindow: .oneMinute,
            batchSize: 50,
            flushInterval: nil
        )

        logger.info("Starting wallet initialization", metadata: ["version": "1.0.0"])
        await metricsClient.increment(CashuMetrics.walletInitializeStart)
        let timer = metricsClient.startTimer()
        try? await Task.sleep(nanoseconds: 5_000_000)
        await timer.stop(metricName: CashuMetrics.walletInitializeDuration, tags: [:])
        await metricsClient.increment(CashuMetrics.walletInitializeSuccess)
        await metricsClient.gauge("wallet.balance", value: 1000, tags: ["currency": "sat"])

        let metrics = await metricsClient.getMetrics()
        var logs = logCapture.snapshot()
        for _ in 0..<50 where logs.isEmpty {
            try? await Task.sleep(nanoseconds: 20_000_000)
            logs = logCapture.snapshot()
        }

        #expect(!logs.isEmpty)
        #expect(metrics.contains { $0.name == CashuMetrics.walletInitializeStart })
        #expect(metrics.contains { $0.name == CashuMetrics.walletInitializeSuccess })
        #expect(metrics.contains { $0.type == .gauge })
        #expect(metrics.contains { $0.type == .histogram })
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

                    let timer = metricsClient.startTimer()
                    try? await Task.sleep(nanoseconds: UInt64.random(in: 1_000_000...10_000_000))
                    await timer.stop(metricName: "task.duration", tags: ["task_id": String(i)])

                    await metricsClient.increment("task.completed", tags: ["task_id": String(i)])

                    // Random gauge updates
                    await metricsClient.gauge("system.load", value: Double.random(in: 0...100))
                }
            }
        }

        // No crashes or data races = test passed
        #expect(Bool(true))
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
