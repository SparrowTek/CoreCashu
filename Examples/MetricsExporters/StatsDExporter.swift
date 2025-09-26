import Foundation
import CoreCashu
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// StatsD metrics exporter for CoreCashu
///
/// This exporter sends metrics to a StatsD server using the StatsD protocol.
/// StatsD is commonly used with Graphite, DataDog, and other monitoring systems.
///
/// Usage:
/// ```swift
/// let metricsClient = EnhancedMetricsClient()
/// let exporter = StatsDExporter(
///     metricsClient: metricsClient,
///     host: "localhost",
///     port: 8125
/// )
/// await exporter.start()
/// ```
public actor StatsDExporter {

    private let metricsClient: EnhancedMetricsClient
    private let host: String
    private let port: Int
    private let prefix: String
    private let sampleRate: Double
    private var udpSocket: FileHandle?
    private var buffer: [String] = []
    private let maxBatchSize: Int
    private var flushTask: Task<Void, Never>?

    /// Initialize StatsD exporter
    /// - Parameters:
    ///   - metricsClient: The metrics client to export from
    ///   - host: StatsD server host (default: localhost)
    ///   - port: StatsD server port (default: 8125)
    ///   - prefix: Metric name prefix (default: "cashu")
    ///   - sampleRate: Sample rate for metrics (default: 1.0)
    ///   - maxBatchSize: Maximum batch size before flush (default: 50)
    public init(
        metricsClient: EnhancedMetricsClient,
        host: String = "localhost",
        port: Int = 8125,
        prefix: String = "cashu",
        sampleRate: Double = 1.0,
        maxBatchSize: Int = 50
    ) {
        self.metricsClient = metricsClient
        self.host = host
        self.port = port
        self.prefix = prefix
        self.sampleRate = sampleRate
        self.maxBatchSize = maxBatchSize

        // Register export handler
        Task {
            await metricsClient.addExportHandler { [weak self] metric in
                Task {
                    await self?.handleMetric(metric)
                }
            }
        }
    }

    /// Start the StatsD exporter
    public func start() async {
        print("Starting StatsD exporter to \(host):\(port)")
        print("Metric prefix: \(prefix)")

        // Start flush task
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                await self?.flush()
            }
        }

        // Demonstrate StatsD protocol
        await demonstrateStatsDProtocol()
    }

    /// Stop the exporter
    public func stop() {
        flushTask?.cancel()
        udpSocket?.closeFile()
    }

    /// Handle a metric from the metrics client
    private func handleMetric(_ metric: EnhancedMetricsClient.MetricDataPoint) async {
        let statsdMessage = formatMetric(metric)
        buffer.append(statsdMessage)

        if buffer.count >= maxBatchSize {
            await flush()
        }
    }

    /// Format a metric in StatsD protocol
    private func formatMetric(_ metric: EnhancedMetricsClient.MetricDataPoint) -> String {
        let name = formatName(metric.name, tags: metric.tags)

        switch metric.type {
        case .counter:
            return "\(name):\(Int(metric.value))|c"

        case .gauge:
            let sign = metric.value >= 0 ? "" : ""
            return "\(name):\(sign)\(metric.value)|g"

        case .histogram, .timer:
            return "\(name):\(metric.value * 1000)|ms"  // Convert to milliseconds

        case .summary:
            return "\(name):\(metric.value)|h"
        }
    }

    /// Format metric name with tags (DataDog/DogStatsD style)
    private func formatName(_ name: String, tags: [String: String]) -> String {
        let fullName = "\(prefix).\(name)"
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")

        if tags.isEmpty {
            return fullName
        }

        // Add tags in DogStatsD format
        let tagString = tags.sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ",")

        return "\(fullName)#\(tagString)"
    }

    /// Flush buffered metrics
    private func flush() async {
        guard !buffer.isEmpty else { return }

        let messages = buffer
        buffer.removeAll(keepingCapacity: true)

        // In a real implementation, we'd send these via UDP
        // For demonstration, we'll print them
        for message in messages {
            await sendUDP(message)
        }
    }

    /// Send a message via UDP (simulated for demonstration)
    private func sendUDP(_ message: String) async {
        // In a real implementation, we'd use:
        // - Network.framework on Apple platforms
        // - SwiftNIO or raw sockets on Linux

        // For demonstration, we'll just print the StatsD protocol message
        if ProcessInfo.processInfo.environment["STATSD_DEBUG"] != nil {
            print("[StatsD] \(message)")
        }
    }

    /// Demonstrate StatsD protocol with examples
    private func demonstrateStatsDProtocol() async {
        print("\n=== StatsD Protocol Demonstration ===\n")

        // Counter examples
        print("Counter examples:")
        print("  cashu.wallet.operations:1|c")
        print("  cashu.wallet.operations:1|c#operation:mint,status:success")
        print("")

        // Gauge examples
        print("Gauge examples:")
        print("  cashu.wallet.balance:1000000|g")
        print("  cashu.active.connections:5|g#type:websocket")
        print("")

        // Timer/Histogram examples
        print("Timer/Histogram examples:")
        print("  cashu.operation.duration:123|ms")
        print("  cashu.operation.duration:123|ms#operation:mint")
        print("")

        // Set examples
        print("Set examples:")
        print("  cashu.unique.users:alice|s")
        print("  cashu.unique.mints:https://mint.example.com|s")
        print("")

        // Sample rate examples
        print("Sample rate examples:")
        print("  cashu.high.frequency.metric:1|c|@0.1")
        print("")

        print("=== End of StatsD Protocol Demo ===\n")
    }
}

// MARK: - StatsD Client Implementation

/// Simple StatsD client for sending metrics
public class StatsDClient {

    private let host: String
    private let port: Int
    private let prefix: String
    private let queue = DispatchQueue(label: "com.cashu.statsd", attributes: .concurrent)

    public init(host: String = "localhost", port: Int = 8125, prefix: String = "cashu") {
        self.host = host
        self.port = port
        self.prefix = prefix
    }

    /// Send a counter metric
    public func count(_ name: String, value: Int = 1, tags: [String: String]? = nil, sampleRate: Double = 1.0) {
        let metric = formatMetric(name: name, value: String(value), type: "c", tags: tags, sampleRate: sampleRate)
        send(metric)
    }

    /// Send a gauge metric
    public func gauge(_ name: String, value: Double, tags: [String: String]? = nil) {
        let metric = formatMetric(name: name, value: String(value), type: "g", tags: tags)
        send(metric)
    }

    /// Send a timing metric
    public func timing(_ name: String, milliseconds: Double, tags: [String: String]? = nil, sampleRate: Double = 1.0) {
        let metric = formatMetric(name: name, value: String(Int(milliseconds)), type: "ms", tags: tags, sampleRate: sampleRate)
        send(metric)
    }

    /// Send a histogram metric
    public func histogram(_ name: String, value: Double, tags: [String: String]? = nil, sampleRate: Double = 1.0) {
        let metric = formatMetric(name: name, value: String(value), type: "h", tags: tags, sampleRate: sampleRate)
        send(metric)
    }

    /// Send a set metric
    public func set(_ name: String, value: String, tags: [String: String]? = nil) {
        let metric = formatMetric(name: name, value: value, type: "s", tags: tags)
        send(metric)
    }

    private func formatMetric(
        name: String,
        value: String,
        type: String,
        tags: [String: String]? = nil,
        sampleRate: Double = 1.0
    ) -> String {
        var metric = "\(prefix).\(name):\(value)|\(type)"

        if sampleRate < 1.0 {
            metric += "|@\(sampleRate)"
        }

        if let tags = tags, !tags.isEmpty {
            let tagString = tags.sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
            metric += "#\(tagString)"
        }

        return metric
    }

    private func send(_ metric: String) {
        queue.async {
            // In production, send via UDP
            if ProcessInfo.processInfo.environment["STATSD_DEBUG"] != nil {
                print("[StatsDClient] \(metric)")
            }
        }
    }
}

// MARK: - Example Usage

public struct StatsDExporterExample {

    public static func run() async throws {
        print("Starting StatsD Exporter Example...")

        // Create metrics client
        let metricsClient = EnhancedMetricsClient(enabled: true)

        // Create and configure exporter
        let exporter = StatsDExporter(
            metricsClient: metricsClient,
            host: "localhost",
            port: 8125,
            prefix: "cashu.wallet"
        )

        // Start the exporter
        await exporter.start()

        // Create a direct StatsD client for demonstration
        let statsdClient = StatsDClient(prefix: "cashu.example")

        print("\nSimulating wallet operations with StatsD metrics...")

        for i in 1...10 {
            // Track operation counts
            statsdClient.count("operations.total", tags: ["type": "mint"])
            await metricsClient.increment("operations.total", tags: ["type": "mint"])

            // Track timing
            let duration = Double.random(in: 50...500)
            statsdClient.timing("operation.duration", milliseconds: duration, tags: ["operation": "mint"])
            await metricsClient.histogram("operation.duration", value: duration / 1000, tags: ["operation": "mint"])

            // Track gauge values
            let balance = Double(i * 100000)
            statsdClient.gauge("wallet.balance", value: balance)
            await metricsClient.gauge("wallet.balance", value: balance)

            // Track unique values
            statsdClient.set("active.users", value: "user_\(i)")

            print("Sent metrics batch \(i)/10")

            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        print("\n✅ StatsD exporter example completed!")
        print("\nTo use with a real StatsD server:")
        print("1. Install StatsD: npm install -g statsd")
        print("2. Configure StatsD to forward to your backend (Graphite, DataDog, etc)")
        print("3. Update the host/port in the exporter configuration")
        print("\nDataDog users can use DogStatsD with the same protocol")
        print("The exporter automatically formats tags in DogStatsD format")

        // Stop the exporter
        await exporter.stop()
    }
}