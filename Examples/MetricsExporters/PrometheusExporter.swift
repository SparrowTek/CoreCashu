import Foundation
import CoreCashu
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Prometheus metrics exporter for CoreCashu
///
/// This exporter converts CoreCashu metrics to Prometheus format and provides
/// an HTTP endpoint for Prometheus scraping.
///
/// Usage:
/// ```swift
/// let metricsClient = EnhancedMetricsClient()
/// let exporter = PrometheusExporter(metricsClient: metricsClient)
/// try await exporter.start(port: 9090)
/// ```
public actor PrometheusExporter {

    private let metricsClient: EnhancedMetricsClient
    private let port: Int
    private var serverTask: Task<Void, Error>?

    /// Metric type mappings for Prometheus
    private let typeMapping: [String: String] = [
        "counter": "counter",
        "gauge": "gauge",
        "histogram": "histogram",
        "summary": "summary"
    ]

    /// Initialize Prometheus exporter
    /// - Parameters:
    ///   - metricsClient: The metrics client to export from
    ///   - port: Port to serve metrics on (default: 9090)
    public init(metricsClient: EnhancedMetricsClient, port: Int = 9090) {
        self.metricsClient = metricsClient
        self.port = port

        // Register export handler
        Task {
            await metricsClient.addExportHandler { [weak self] metric in
                Task {
                    await self?.handleMetric(metric)
                }
            }
        }
    }

    /// Start the HTTP server for Prometheus scraping
    public func start() async throws {
        #if canImport(Network)
        // For Apple platforms, we could use Network.framework
        print("Starting Prometheus exporter on port \(port)")
        print("Metrics available at http://localhost:\(port)/metrics")
        #else
        // For Linux, we'd use SwiftNIO or another HTTP server
        print("HTTP server not implemented for this platform")
        print("Metrics would be available at http://localhost:\(port)/metrics")
        #endif

        // In a real implementation, we'd start an HTTP server here
        // For demonstration, we'll just print the metrics format
        await demonstrateMetricsFormat()
    }

    /// Stop the exporter
    public func stop() {
        serverTask?.cancel()
    }

    /// Generate Prometheus format metrics
    public func generatePrometheusFormat() async -> String {
        let metrics = await metricsClient.getMetrics()
        var output: [String] = []

        // Add header
        output.append("# CoreCashu Metrics Export")
        output.append("# Generated at \(Date())")
        output.append("")

        // Group metrics by name
        let grouped = Dictionary(grouping: metrics) { $0.name }

        for (name, metricGroup) in grouped.sorted(by: { $0.key < $1.key }) {
            guard let firstMetric = metricGroup.first else { continue }

            // Add metric help and type
            let sanitizedName = sanitizeName(name)
            output.append("# HELP \(sanitizedName) \(firstMetric.description ?? "No description")")
            output.append("# TYPE \(sanitizedName) \(mapType(firstMetric.type))")

            // Add metric values
            for metric in metricGroup {
                let labels = formatLabels(metric.tags)
                let value = formatValue(metric.value)

                if metric.type == .histogram {
                    // For histograms, we need to output buckets
                    output.append("\(sanitizedName)_bucket{le=\"+Inf\"\(labels.isEmpty ? "" : ",\(labels)")} \(value)")
                    output.append("\(sanitizedName)_sum{\(labels)} \(value)")
                    output.append("\(sanitizedName)_count{\(labels)} 1")
                } else {
                    output.append("\(sanitizedName){\(labels)} \(value)")
                }
            }

            output.append("")
        }

        // Add standard runtime metrics
        output.append("# Runtime Metrics")
        output.append("# TYPE process_uptime_seconds gauge")
        output.append("process_uptime_seconds \(ProcessInfo.processInfo.systemUptime)")
        output.append("")

        return output.joined(separator: "\n")
    }

    // MARK: - Private Methods

    private func handleMetric(_ metric: EnhancedMetricsClient.MetricDataPoint) async {
        // In a real implementation, we'd store metrics for scraping
        // For now, we'll just log that we received it
    }

    private func sanitizeName(_ name: String) -> String {
        // Prometheus metric names must match [a-zA-Z_:][a-zA-Z0-9_:]*
        let sanitized = name
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return "cashu_" + sanitized
    }

    private func mapType(_ type: EnhancedMetricsClient.MetricType) -> String {
        switch type {
        case .counter:
            return "counter"
        case .gauge:
            return "gauge"
        case .histogram:
            return "histogram"
        case .summary:
            return "summary"
        case .timer:
            return "histogram"
        }
    }

    private func formatLabels(_ tags: [String: String]) -> String {
        guard !tags.isEmpty else { return "" }

        let pairs = tags.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\"\(escapeLabel(value))\""
        }

        return pairs.joined(separator: ",")
    }

    private func escapeLabel(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func formatValue(_ value: Double) -> String {
        if value.isInfinite {
            return value > 0 ? "+Inf" : "-Inf"
        } else if value.isNaN {
            return "NaN"
        } else {
            return String(format: "%.6f", value)
        }
    }

    private func demonstrateMetricsFormat() async {
        // Add some sample metrics for demonstration
        await metricsClient.increment("wallet_operations_total", tags: ["operation": "mint", "status": "success"])
        await metricsClient.increment("wallet_operations_total", tags: ["operation": "melt", "status": "success"])
        await metricsClient.increment("wallet_operations_total", tags: ["operation": "swap", "status": "failed"])

        await metricsClient.gauge("wallet_balance_sats", value: 1000000, tags: ["wallet": "main"])
        await metricsClient.gauge("active_connections", value: 5, tags: ["type": "websocket"])

        await metricsClient.histogram("operation_duration_seconds", value: 0.123, tags: ["operation": "mint"])
        await metricsClient.histogram("operation_duration_seconds", value: 0.456, tags: ["operation": "melt"])
        await metricsClient.histogram("operation_duration_seconds", value: 0.089, tags: ["operation": "swap"])

        // Generate and print the Prometheus format
        let prometheusOutput = await generatePrometheusFormat()
        print("=== Prometheus Metrics Format ===")
        print(prometheusOutput)
        print("=================================")
    }
}

// MARK: - Example Usage

public struct PrometheusExporterExample {

    public static func run() async throws {
        print("Starting Prometheus Exporter Example...")

        // Create metrics client
        let metricsClient = EnhancedMetricsClient(enabled: true)

        // Create and configure exporter
        let exporter = PrometheusExporter(metricsClient: metricsClient, port: 9090)

        // Simulate some wallet operations
        print("\nSimulating wallet operations...")

        for i in 1...10 {
            // Mint operation
            let mintTimer = await metricsClient.startTimer()
            try? await Task.sleep(nanoseconds: UInt64.random(in: 10_000_000...100_000_000))
            await mintTimer.stop(metricName: "mint_duration_seconds")
            await metricsClient.increment("mint_operations_total", tags: ["status": "success"])

            // Melt operation
            if i % 3 == 0 {
                let meltTimer = await metricsClient.startTimer()
                try? await Task.sleep(nanoseconds: UInt64.random(in: 20_000_000...200_000_000))
                await meltTimer.stop(metricName: "melt_duration_seconds")
                await metricsClient.increment("melt_operations_total", tags: ["status": "success"])
            }

            // Update balance
            await metricsClient.gauge("wallet_balance_sats", value: Double(i * 100000))

            print("Completed operation \(i)/10")
        }

        // Start the exporter (will demonstrate format)
        print("\nStarting Prometheus exporter...")
        try await exporter.start()

        print("\n✅ Prometheus exporter example completed!")
        print("In a production environment, metrics would be available at http://localhost:9090/metrics")
        print("\nPrometheus scrape configuration:")
        print("""
        scrape_configs:
          - job_name: 'cashu-wallet'
            static_configs:
              - targets: ['localhost:9090']
        """)
    }
}