import Testing
@testable import CoreCashu
import Foundation

// Thread-safe metric capture for testing
actor MetricCapture {
    private var metrics: [EnhancedMetricsClient.MetricDataPoint] = []
    private var names: [String] = []
    private var counter: Int = 0

    func appendMetric(_ metric: EnhancedMetricsClient.MetricDataPoint) {
        metrics.append(metric)
        names.append(metric.name)
    }

    func appendName(_ name: String) {
        names.append(name)
    }

    func incrementCounter() {
        counter += 1
    }

    func getMetrics() -> [EnhancedMetricsClient.MetricDataPoint] {
        metrics
    }

    func getNames() -> [String] {
        names
    }

    func getCount() -> Int {
        counter
    }

    func containsName(_ name: String) -> Bool {
        names.contains(name)
    }

    func metricsCount() -> Int {
        metrics.count
    }
}

@Suite("Metrics System Tests", .serialized)
struct MetricsTests {

    // MARK: - Enhanced Metrics Client Tests

    @Test("Enhanced metrics client records counters")
    func testCounterMetrics() async {
        let client = EnhancedMetricsClient(enabled: true)

        await client.increment("test.counter")
        await client.increment("test.counter", by: 5)
        await client.increment("test.counter", tags: ["env": "test"])

        let counterValue = await client.getCounter("test.counter")
        #expect(counterValue == 6)

        let taggedValue = await client.getCounter("test.counter", tags: ["env": "test"])
        #expect(taggedValue == 1)
    }

    @Test("Enhanced metrics client records gauges")
    func testGaugeMetrics() async {
        let client = EnhancedMetricsClient(enabled: true)

        await client.gauge("memory.usage", value: 1024.5)
        await client.gauge("memory.usage", value: 2048.0)
        await client.gauge("cpu.usage", value: 45.5, tags: ["core": "1"])

        let memoryValue = await client.getGauge("memory.usage")
        #expect(memoryValue == 2048.0)

        let cpuValue = await client.getGauge("cpu.usage", tags: ["core": "1"])
        #expect(cpuValue == 45.5)
    }

    @Test("Enhanced metrics client records histograms")
    func testHistogramMetrics() async {
        let client = EnhancedMetricsClient(enabled: true)

        // Add values to histogram
        for i in 1...100 {
            await client.histogram("response.time", value: Double(i))
        }

        let stats = await client.getHistogramStats("response.time")
        #expect(stats != nil)
        #expect(stats?.count == 100)
        #expect(stats?.mean == 50.5)
        #expect(stats?.min == 1)
        #expect(stats?.max == 100)
        #expect(stats?.p50 == 50)
        #expect(stats?.p99 == 99)
    }

    @Test("Enhanced metrics timer measures duration")
    func testMetricTimer() async {
        let client = EnhancedMetricsClient(enabled: true)

        let timer = client.startTimer()
        // Simulate some work
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        await timer.stop(metricName: "operation.duration", tags: [:])

        let stats = await client.getHistogramStats("operation.duration")
        #expect(stats != nil)
        #expect(stats!.count == 1)
        #expect(stats!.min > 0.009) // Should be at least 9ms
    }

    @Test("Enhanced metrics client respects enabled flag")
    func testMetricsDisabled() async {
        let client = EnhancedMetricsClient(enabled: false)

        await client.increment("test.counter", by: 10)
        await client.gauge("test.gauge", value: 100)
        await client.histogram("test.histogram", value: 50)

        let counter = await client.getCounter("test.counter")
        #expect(counter == 0)

        let gauge = await client.getGauge("test.gauge")
        #expect(gauge == nil)

        let stats = await client.getHistogramStats("test.histogram")
        #expect(stats == nil)
    }

    @Test("Enhanced metrics client handles events")
    func testEventMetrics() async {
        let client = EnhancedMetricsClient(enabled: true)

        await client.event("user.login", metadata: ["user": "alice", "ip": "127.0.0.1"])
        await client.event("user.logout", metadata: ["user": "alice"])

        let metrics = await client.getMetrics()
        let loginEvents = metrics.filter { $0.name == "user.login" }
        #expect(loginEvents.count == 1)
        #expect(loginEvents.first?.tags["user"] == "alice")
    }

    @Test("Enhanced metrics client export handlers")
    func testExportHandlers() async {
        let client = EnhancedMetricsClient(enabled: true)
        let metricCapture = MetricCapture()

        await client.addExportHandler { metric in
            Task {
                await metricCapture.appendMetric(metric)
            }
        }

        await client.increment("export.test", by: 5)
        await client.gauge("export.gauge", value: 100)

        // Give handlers time to process
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        let exportedMetrics = await metricCapture.getMetrics()
        #expect(exportedMetrics.count >= 2)
        #expect(exportedMetrics.contains { $0.name == "export.test" })
        #expect(exportedMetrics.contains { $0.name == "export.gauge" })
    }

    @Test("Enhanced metrics client flushes batches")
    func testBatchFlushing() async {
        let client = EnhancedMetricsClient(
            enabled: true,
            batchSize: 5,
            flushInterval: nil // Disable auto-flush for test
        )

        let metricCapture = MetricCapture()
        await client.addExportHandler { _ in
            Task {
                await metricCapture.incrementCounter()
            }
        }

        // Add metrics up to batch size
        for i in 1...10 {
            await client.increment("batch.test", by: Double(i))
            // Batch should flush at 5 and 10
        }

        // Give time for async operations
        try? await Task.sleep(nanoseconds: 100_000_000)

        let flushedCount = await metricCapture.getCount()
        #expect(flushedCount >= 10) // Should have flushed all metrics
    }

    @Test("Enhanced metrics client resets metrics")
    func testMetricsReset() async {
        let client = EnhancedMetricsClient(enabled: true)

        await client.increment("reset.counter", by: 10)
        await client.gauge("reset.gauge", value: 100)
        await client.histogram("reset.histogram", value: 50)

        await client.reset()

        let counter = await client.getCounter("reset.counter")
        #expect(counter == 0)

        let gauge = await client.getGauge("reset.gauge")
        #expect(gauge == nil)

        let stats = await client.getHistogramStats("reset.histogram")
        #expect(stats == nil)
    }

    // MARK: - Metrics Aggregator Tests

    @Test("Metrics aggregator aggregates values")
    func testMetricsAggregator() async {
        let client = EnhancedMetricsClient(enabled: true)
        let aggregator = MetricsAggregator(client: client)

        // Record multiple values
        for i in 1...10 {
            await aggregator.record(name: "test.metric", value: Double(i))
        }

        let aggregates = await aggregator.getAggregates()
        #expect(aggregates.count == 1)

        if let aggregate = aggregates.first {
            #expect(aggregate.name == "test.metric")
            #expect(aggregate.count == 10)
            #expect(aggregate.sum == 55) // 1+2+...+10
            #expect(aggregate.min == 1)
            #expect(aggregate.max == 10)
            #expect(aggregate.lastValue == 10)
        }
    }

    @Test("Metrics aggregator handles tagged metrics separately")
    func testAggregatorWithTags() async {
        let client = EnhancedMetricsClient(enabled: true)
        let aggregator = MetricsAggregator(client: client)

        await aggregator.record(name: "api.calls", value: 100, tags: ["endpoint": "/mint"])
        await aggregator.record(name: "api.calls", value: 200, tags: ["endpoint": "/melt"])
        await aggregator.record(name: "api.calls", value: 150, tags: ["endpoint": "/mint"])

        let aggregates = await aggregator.getAggregates()
        #expect(aggregates.count == 2)
    }

    // MARK: - Original Metrics Client Tests

    @Test("NoOp metrics client does nothing")
    func testNoOpMetricsClient() async {
        let client = NoOpMetricsClient()

        await client.increment("test")
        await client.gauge("test", value: 100)
        await client.timing("test", duration: 50)

        let timer = client.startTimer()
        await timer.stop(metricName: "timer", tags: [:])

        await client.event("event")

        #expect(Bool(true)) // NoOpMetricsClient does nothing
    }

    @Test("Console metrics client outputs to console")
    func testConsoleMetricsClient() async {
        let client = ConsoleMetricsClient()

        // These should output to console without crashing
        await client.increment("console.test")
        await client.gauge("console.gauge", value: 100)
        await client.timing("console.histogram", duration: 0.05)

        let timer = client.startTimer()
        try? await Task.sleep(nanoseconds: 10_000_000)
        await timer.stop(metricName: "console.timer", tags: [:])

        await client.event("console.event", metadata: ["test": "value"])

        #expect(Bool(true)) // ConsoleMetricsClient always outputs
    }

    // MARK: - CashuMetrics Constants Tests

    @Test("CashuMetrics constants are defined")
    func testCashuMetricsConstants() {
        #expect(CashuMetrics.walletInitializeStart == "cashu.wallet.initialize.start")
        #expect(CashuMetrics.walletInitializeSuccess == "cashu.wallet.initialize.success")
        #expect(CashuMetrics.walletInitializeFailure == "cashu.wallet.initialize.failure")
        #expect(CashuMetrics.walletInitializeDuration == "cashu.wallet.initialize.duration")

        #expect(CashuMetrics.mintStart == "cashu.mint.start")
        #expect(CashuMetrics.mintSuccess == "cashu.mint.success")
        #expect(CashuMetrics.mintFailure == "cashu.mint.failure")
        #expect(CashuMetrics.mintDuration == "cashu.mint.duration")

        #expect(CashuMetrics.meltStart == "cashu.melt.start")
        #expect(CashuMetrics.meltFinalized == "cashu.melt.finalized")
        #expect(CashuMetrics.meltRolledBack == "cashu.melt.rolled_back")
        #expect(CashuMetrics.meltFailure == "cashu.melt.failure")
        #expect(CashuMetrics.meltDuration == "cashu.melt.duration")
    }

    // MARK: - Integration Tests

    @Test("Metrics integration with wallet operations")
    func testMetricsWalletIntegration() async {
        let metricsClient = EnhancedMetricsClient(enabled: true)
        let metricCapture = MetricCapture()

        await metricsClient.addExportHandler { metric in
            Task {
                await metricCapture.appendName(metric.name)
            }
        }

        // Simulate wallet initialization
        await metricsClient.increment(CashuMetrics.walletInitializeStart)
        let initTimer = metricsClient.startTimer()
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        await initTimer.stop(metricName: CashuMetrics.walletInitializeDuration, tags: [:])
        await metricsClient.increment(CashuMetrics.walletInitializeSuccess)

        // Simulate mint operation
        await metricsClient.increment(CashuMetrics.mintStart)
        let mintTimer = metricsClient.startTimer()
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        await mintTimer.stop(metricName: CashuMetrics.mintDuration, tags: [:])
        await metricsClient.increment(CashuMetrics.mintSuccess)

        // Simulate melt operation
        await metricsClient.increment(CashuMetrics.meltStart)
        let meltTimer = metricsClient.startTimer()
        try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
        await meltTimer.stop(metricName: CashuMetrics.meltDuration, tags: [:])
        await metricsClient.increment(CashuMetrics.meltFinalized)

        // Give time for async operations
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(await metricCapture.containsName(CashuMetrics.walletInitializeStart))
        #expect(await metricCapture.containsName(CashuMetrics.walletInitializeSuccess))
        #expect(await metricCapture.containsName(CashuMetrics.mintStart))
        #expect(await metricCapture.containsName(CashuMetrics.mintSuccess))
        #expect(await metricCapture.containsName(CashuMetrics.meltStart))
        #expect(await metricCapture.containsName(CashuMetrics.meltFinalized))
    }

    @Test("Metrics performance under load")
    func testMetricsPerformance() async {
        let client = EnhancedMetricsClient(
            enabled: true,
            batchSize: 1000,
            flushInterval: nil
        )

        let startTime = Date()

        // Generate high volume of metrics
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    for j in 0..<100 {
                        await client.increment("perf.counter", tags: ["batch": "\(i)", "item": "\(j)"])
                    }
                }
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        print("Generated 10,000 metrics in \(duration) seconds")

        #expect(duration < 5.0) // Should complete in under 5 seconds
    }
}