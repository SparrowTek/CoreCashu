import Foundation

/// Enhanced metrics client with advanced features
@preconcurrency public actor EnhancedMetricsClient: MetricsClient {

    /// Metric types
    public enum MetricType: Sendable {
        case counter
        case gauge
        case histogram
        case summary
        case timer
    }

    /// Metric data point
    public struct MetricDataPoint: Sendable {
        public let name: String
        public let value: Double
        public let type: MetricType
        public let tags: [String: String]
        public let timestamp: Date
        public let unit: String?
        public let description: String?
    }

    /// Aggregation window for metrics
    public struct AggregationWindow: Sendable {
        public let duration: TimeInterval
        public let buckets: Int

        public static let oneMinute = AggregationWindow(duration: 60, buckets: 60)
        public static let fiveMinutes = AggregationWindow(duration: 300, buckets: 60)
        public static let fifteenMinutes = AggregationWindow(duration: 900, buckets: 90)
        public static let oneHour = AggregationWindow(duration: 3600, buckets: 60)
    }

    /// Histogram buckets for latency metrics
    public static let defaultLatencyBuckets: [Double] = [
        0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0
    ]

    private var enabled: Bool
    private var metrics: [MetricDataPoint] = []
    private var counters: [String: Double] = [:]
    private var gauges: [String: Double] = [:]
    private var histograms: [String: [Double]] = [:]
    private var aggregationWindow: AggregationWindow
    private var exportHandlers: [(MetricDataPoint) -> Void] = []
    private var batchSize: Int
    private var flushInterval: TimeInterval?
    private var flushTask: Task<Void, Never>?

    /// Initialize enhanced metrics client
    public init(
        enabled: Bool = true,
        aggregationWindow: AggregationWindow = .fiveMinutes,
        batchSize: Int = 100,
        flushInterval: TimeInterval? = 10.0
    ) {
        self.enabled = enabled
        self.aggregationWindow = aggregationWindow
        self.batchSize = batchSize
        self.flushInterval = flushInterval
        self.flushTask = nil

        Task { [weak self] in
            guard let self = self, let interval = flushInterval else { return }
            await self.startFlushTask(interval: interval)
        }
    }

    private func startFlushTask(interval: TimeInterval) {
        self.flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                await self?.flush()
            }
        }
    }

    deinit {
        flushTask?.cancel()
    }

    // MARK: - MetricsClient Protocol

    public func isEnabled() async -> Bool {
        enabled
    }

    public func increment(_ name: String, tags: [String: String] = [:]) async {
        await increment(name, by: 1, tags: tags)
    }

    public func increment(
        _ name: String,
        by value: Double = 1,
        tags: [String: String] = [:]
    ) async {
        guard enabled else { return }

        let key = metricKey(name: name, tags: tags)
        counters[key, default: 0] += value

        let metric = MetricDataPoint(
            name: name,
            value: value,
            type: .counter,
            tags: tags,
            timestamp: Date(),
            unit: nil,
            description: nil
        )

        await record(metric)
    }

    public func gauge(
        _ name: String,
        value: Double,
        tags: [String: String] = [:]
    ) async {
        guard enabled else { return }

        let key = metricKey(name: name, tags: tags)
        gauges[key] = value

        let metric = MetricDataPoint(
            name: name,
            value: value,
            type: .gauge,
            tags: tags,
            timestamp: Date(),
            unit: nil,
            description: nil
        )

        await record(metric)
    }

    public func histogram(_ name: String, value: Double, tags: [String: String] = [:]) async {
        await histogram(name, value: value, buckets: nil, tags: tags)
    }

    public func histogram(
        _ name: String,
        value: Double,
        buckets: [Double]? = nil,
        tags: [String: String] = [:]
    ) async {
        guard enabled else { return }

        let key = metricKey(name: name, tags: tags)
        histograms[key, default: []].append(value)

        let metric = MetricDataPoint(
            name: name,
            value: value,
            type: .histogram,
            tags: tags,
            timestamp: Date(),
            unit: nil,
            description: nil
        )

        await record(metric)
    }

    public func timing(_ name: String, duration: TimeInterval, tags: [String: String] = [:]) async {
        await histogram(name, value: duration, tags: tags)
    }

    public nonisolated func startTimer() -> any MetricTimer {
        EnhancedMetricTimer(client: self)
    }

    public nonisolated func event(
        _ name: String,
        metadata: [String: Any]? = nil
    ) async {
        let tags: [String: String] = metadata?.reduce(into: [:]) { result, pair in
            result[pair.key] = String(describing: pair.value)
        } ?? [:]

        await recordEvent(name: name, tags: tags)
    }

    private func recordEvent(name: String, tags: [String: String]) async {
        guard enabled else { return }

        let metric = MetricDataPoint(
            name: name,
            value: 1,
            type: .counter,
            tags: tags,
            timestamp: Date(),
            unit: nil,
            description: "event"
        )

        await record(metric)
    }

    // MARK: - Enhanced Features

    /// Add an export handler for metrics
    public func addExportHandler(_ handler: @escaping (MetricDataPoint) -> Void) {
        exportHandlers.append(handler)
    }

    /// Get current counter value
    public func getCounter(_ name: String, tags: [String: String]? = nil) async -> Double {
        let key = metricKey(name: name, tags: tags)
        return counters[key] ?? 0
    }

    /// Get current gauge value
    public func getGauge(_ name: String, tags: [String: String]? = nil) async -> Double? {
        let key = metricKey(name: name, tags: tags)
        return gauges[key]
    }

    /// Get histogram statistics
    public func getHistogramStats(
        _ name: String,
        tags: [String: String]? = nil
    ) async -> HistogramStatistics? {
        let key = metricKey(name: name, tags: tags)
        guard let values = histograms[key], !values.isEmpty else { return nil }

        let sorted = values.sorted()
        return HistogramStatistics(
            count: values.count,
            sum: values.reduce(0, +),
            mean: values.reduce(0, +) / Double(values.count),
            min: sorted.first ?? 0,
            max: sorted.last ?? 0,
            p50: percentile(sorted, 0.5),
            p90: percentile(sorted, 0.9),
            p95: percentile(sorted, 0.95),
            p99: percentile(sorted, 0.99)
        )
    }

    /// Reset all metrics
    public func reset() async {
        metrics.removeAll()
        counters.removeAll()
        gauges.removeAll()
        histograms.removeAll()
    }

    /// Flush metrics to export handlers
    public func flush() async {
        let metricsToExport = metrics
        metrics.removeAll(keepingCapacity: true)

        for metric in metricsToExport {
            for handler in exportHandlers {
                handler(metric)
            }
        }
    }

    /// Get all recorded metrics
    public func getMetrics() async -> [MetricDataPoint] {
        metrics
    }

    /// Enable/disable metrics collection
    public func setEnabled(_ enabled: Bool) async {
        self.enabled = enabled
    }

    // MARK: - Private Methods

    private func record(_ metric: MetricDataPoint) async {
        metrics.append(metric)

        // Export to handlers
        for handler in exportHandlers {
            handler(metric)
        }

        // Auto-flush if batch size reached
        if metrics.count >= batchSize {
            await flush()
        }

        // Clean up old metrics based on aggregation window
        let cutoff = Date().addingTimeInterval(-aggregationWindow.duration)
        metrics.removeAll { $0.timestamp < cutoff }
    }

    private func metricKey(name: String, tags: [String: String]?) -> String {
        var key = name
        if let tags = tags {
            let sortedTags = tags.sorted { $0.key < $1.key }
            let tagString = sortedTags.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            key += "{\(tagString)}"
        }
        return key
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        let index = Int(Double(values.count - 1) * p)
        return values[index]
    }
}

/// Statistics for histogram metrics
public struct HistogramStatistics: Sendable {
    public let count: Int
    public let sum: Double
    public let mean: Double
    public let min: Double
    public let max: Double
    public let p50: Double
    public let p90: Double
    public let p95: Double
    public let p99: Double
}

/// Enhanced timer implementation
private struct EnhancedMetricTimer: MetricTimer {
    private let startTime = Date()
    private weak var client: EnhancedMetricsClient?

    init(client: EnhancedMetricsClient) {
        self.client = client
    }

    var elapsedTime: TimeInterval {
        Date().timeIntervalSince(startTime)
    }

    func stop(metricName: String, tags: [String: String] = [:]) async {
        let duration = Date().timeIntervalSince(startTime)
        await client?.histogram(
            metricName,
            value: duration,
            buckets: EnhancedMetricsClient.defaultLatencyBuckets,
            tags: tags
        )
    }
}

// MARK: - Metrics Aggregator

/// Aggregates metrics over time windows
public actor MetricsAggregator {

    private let client: EnhancedMetricsClient
    private var aggregates: [String: AggregateMetric] = [:]

    public init(client: EnhancedMetricsClient) {
        self.client = client
    }

    /// Aggregate metric data
    public struct AggregateMetric: Sendable {
        public let name: String
        public let windowStart: Date
        public let windowEnd: Date
        public var count: Int
        public var sum: Double
        public var min: Double
        public var max: Double
        public var lastValue: Double
        public var tags: [String: String]
    }

    /// Record a value for aggregation
    public func record(
        name: String,
        value: Double,
        tags: [String: String]? = nil
    ) {
        let key = "\(name)_\(tags?.description ?? "")"
        let now = Date()

        if var aggregate = aggregates[key] {
            aggregate.count += 1
            aggregate.sum += value
            aggregate.min = min(aggregate.min, value)
            aggregate.max = max(aggregate.max, value)
            aggregate.lastValue = value
            aggregates[key] = aggregate
        } else {
            aggregates[key] = AggregateMetric(
                name: name,
                windowStart: now,
                windowEnd: now.addingTimeInterval(60), // 1 minute window
                count: 1,
                sum: value,
                min: value,
                max: value,
                lastValue: value,
                tags: tags ?? [:]
            )
        }
    }

    /// Get aggregated metrics
    public func getAggregates() -> [AggregateMetric] {
        Array(aggregates.values)
    }

    /// Clear old aggregates
    public func clearOldAggregates() {
        let cutoff = Date().addingTimeInterval(-3600) // Keep last hour
        aggregates = aggregates.filter { $0.value.windowEnd > cutoff }
    }
}
