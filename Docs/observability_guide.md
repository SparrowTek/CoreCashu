# CoreCashu Observability Guide

## Overview

CoreCashu provides comprehensive observability features including structured logging, metrics collection, and secret redaction. This guide covers how to use and configure these features for production environments.

## Table of Contents

1. [Logging System](#logging-system)
2. [Metrics System](#metrics-system)
3. [Secret Redaction](#secret-redaction)
4. [Export Integrations](#export-integrations)
5. [Best Practices](#best-practices)

## Logging System

### Available Loggers

#### OSLogger (Apple Platforms)

The OSLogger uses Apple's unified logging system for optimal performance and integration with Console.app and log collection tools.

```swift
#if canImport(os)
let logger = OSLogger(
    subsystem: "com.myapp.cashu",
    category: "wallet",
    minimumLevel: .info,
    enableRedaction: true
)

// Specialized loggers
let networkLogger = OSLogger.network()
let cryptoLogger = OSLogger.crypto()
let walletLogger = OSLogger.wallet()
let storageLogger = OSLogger.storage()
#endif
```

#### StructuredLogger (Cross-Platform)

The StructuredLogger provides JSON/logfmt output suitable for log aggregation systems.

```swift
let logger = StructuredLogger(
    minimumLevel: .info,
    outputFormat: .jsonLines,
    destination: .stdout,
    enableRedaction: true,
    applicationName: "CashuWallet",
    environment: "production",
    staticMetadata: ["version": "1.0.0"]
)
```

#### Output Formats

- **JSON**: Pretty-printed JSON for human readability
- **JSON Lines**: One JSON object per line for log aggregation
- **logfmt**: Key-value format compatible with many log parsers

#### Output Destinations

- **stdout**: Standard output
- **stderr**: Standard error (for warnings/errors)
- **file(URL)**: Write to a specific file
- **custom((String) -> Void)**: Custom handler

### Log Levels

```swift
public enum LogLevel: Int {
    case debug = 0    // 🔍 Detailed debugging information
    case info = 1     // ℹ️ General informational messages
    case warning = 2  // ⚠️ Warning conditions
    case error = 3    // ❌ Error conditions
    case critical = 4 // 🔥 Critical failures
}
```

### Usage Examples

```swift
// Basic logging
logger.info("Wallet initialized", metadata: ["mintURL": "https://mint.example.com"])

// With context
let context = LogContext(
    mintURL: URL(string: "https://mint.example.com"),
    walletID: "wallet123",
    operation: "mint"
)
logger.debug("Starting mint operation", metadata: context.metadata)

// Error logging with stack trace
logger.error("Mint operation failed", metadata: [
    "error": error.localizedDescription,
    "amount": 1000
])
```

## Metrics System

### Enhanced Metrics Client

The EnhancedMetricsClient provides advanced metrics collection with aggregation, batching, and export capabilities.

```swift
let metricsClient = EnhancedMetricsClient(
    enabled: true,
    aggregationWindow: .fiveMinutes,
    batchSize: 100,
    flushInterval: 10.0
)
```

### Metric Types

#### Counters
Track cumulative values that only increase:

```swift
await metricsClient.increment("wallet.operations.total", tags: ["operation": "mint", "status": "success"])
await metricsClient.increment("errors.total", by: 1, tags: ["type": "network"])
```

#### Gauges
Track values that can go up or down:

```swift
await metricsClient.gauge("wallet.balance.sats", value: 1000000)
await metricsClient.gauge("active.connections", value: 5, tags: ["type": "websocket"])
```

#### Histograms
Track distribution of values:

```swift
await metricsClient.histogram("operation.duration.seconds", value: 0.123, tags: ["operation": "mint"])
```

#### Timers
Measure duration of operations:

```swift
let timer = await metricsClient.startTimer()
// ... perform operation ...
await timer.stop(metricName: "operation.duration", tags: ["operation": "swap"])
```

### Standard Metrics

CoreCashu defines standard metric names in `CashuMetrics`:

```swift
// Wallet lifecycle
CashuMetrics.walletInitializeStart
CashuMetrics.walletInitializeSuccess
CashuMetrics.walletInitializeFailure
CashuMetrics.walletInitializeDuration

// Mint operations
CashuMetrics.mintStart
CashuMetrics.mintSuccess
CashuMetrics.mintFailure
CashuMetrics.mintDuration

// Melt operations
CashuMetrics.meltStart
CashuMetrics.meltFinalized
CashuMetrics.meltRolledBack
CashuMetrics.meltFailure
CashuMetrics.meltDuration
```

## Secret Redaction

### Automatic Redaction

The secret redactor automatically detects and redacts sensitive information:

```swift
let redactor = DefaultSecretRedactor()

// Redacts automatically
let message = "Private key is e7b5e4d6c3a2f1b8d9c7a5e3f2d4c6b8a9d7e5c3f1b9d8c6a4e2f0d8c6b4a2e0"
let redacted = redactor.redact(message)
// Result: "Private key is [REDACTED]"
```

### Redaction Patterns

The following patterns are automatically detected:

- **Mnemonics**: BIP39 mnemonic phrases
- **Private Keys**: 64 hex character strings
- **Seeds**: Hex seeds of various lengths
- **Tokens**: Cashu token strings
- **Secrets**: BDHKE secrets
- **Proofs**: Proof data
- **Witnesses**: Witness signatures
- **Preimages**: HTLC preimages

### Custom Redaction

Add custom redaction patterns:

```swift
let redactor = DefaultSecretRedactor(patterns: [
    .mnemonic,
    .privateKey,
    .customRegex("api_key_[a-zA-Z0-9]{32}")
])
```

### Metadata Redaction

Sensitive keys in metadata are automatically redacted:

```swift
let metadata: [String: Any] = [
    "user": "alice",              // Kept
    "privateKey": "abc123...",    // Redacted
    "amount": 1000                 // Kept
]

let redacted = redactor.redactMetadata(metadata)
// Result: ["user": "alice", "privateKey": "[REDACTED]", "amount": 1000]
```

## Export Integrations

### Prometheus Exporter

Export metrics in Prometheus format:

```swift
let exporter = PrometheusExporter(
    metricsClient: metricsClient,
    port: 9090
)
try await exporter.start()

// Prometheus scrape config:
// scrape_configs:
//   - job_name: 'cashu-wallet'
//     static_configs:
//       - targets: ['localhost:9090']
```

Example output:
```
# HELP cashu_wallet_operations_total Total wallet operations
# TYPE cashu_wallet_operations_total counter
cashu_wallet_operations_total{operation="mint",status="success"} 42
cashu_wallet_operations_total{operation="melt",status="success"} 17
```

### StatsD Exporter

Export metrics to StatsD/DogStatsD:

```swift
let exporter = StatsDExporter(
    metricsClient: metricsClient,
    host: "localhost",
    port: 8125,
    prefix: "cashu"
)
await exporter.start()
```

Example output:
```
cashu.wallet.operations:1|c#operation:mint,status:success
cashu.wallet.balance:1000000|g
cashu.operation.duration:123|ms#operation:mint
```

### Custom Export Handlers

Create custom export handlers:

```swift
await metricsClient.addExportHandler { metric in
    // Send to your monitoring system
    MyMonitoringSystem.send(
        name: metric.name,
        value: metric.value,
        type: metric.type,
        tags: metric.tags,
        timestamp: metric.timestamp
    )
}
```

## Best Practices

### 1. Configure Appropriate Log Levels

```swift
// Development
let logger = StructuredLogger(minimumLevel: .debug)

// Production
let logger = StructuredLogger(minimumLevel: .info)

// High-performance production
let logger = StructuredLogger(minimumLevel: .warning)
```

### 2. Use Structured Metadata

```swift
// Good - structured metadata
logger.info("Payment processed", metadata: [
    "paymentId": paymentId,
    "amount": amount,
    "currency": "sat",
    "duration": duration
])

// Avoid - unstructured strings
logger.info("Payment \(paymentId) processed for \(amount) sats in \(duration)s")
```

### 3. Tag Metrics Consistently

```swift
// Define standard tags
let standardTags = [
    "environment": "production",
    "region": "us-west",
    "version": "1.0.0"
]

// Apply consistently
await metricsClient.increment("operations.total", tags: standardTags.merging(["operation": "mint"]) { $1 })
```

### 4. Handle Sensitive Data

```swift
// Always enable redaction in production
let logger = StructuredLogger(enableRedaction: true)

// Never log sensitive data directly
logger.error("Authentication failed", metadata: [
    "user": username,
    // Don't include password or private keys
    "attempt": attemptNumber
])
```

### 5. Monitor Performance Impact

```swift
// Use sampling for high-frequency metrics
if Double.random(in: 0...1) < 0.1 { // 10% sampling
    await metricsClient.increment("high.frequency.metric")
}

// Batch metrics updates
let aggregator = MetricsAggregator(client: metricsClient)
await aggregator.record(name: "batch.metric", value: value)
```

### 6. Set Up Alerting

Based on exported metrics, set up alerts for:

- Error rate thresholds
- Operation latency percentiles
- Failed operation counts
- Unusual patterns

### 7. Retention Policies

Configure appropriate retention:

```swift
// Short retention for debug logs
let debugLogger = StructuredLogger(
    minimumLevel: .debug,
    destination: .file(debugLogFile)
)

// Long retention for errors
let errorLogger = StructuredLogger(
    minimumLevel: .error,
    destination: .file(errorLogFile)
)
```

## Integration with CashuWallet

```swift
// Initialize wallet with observability
let logger = StructuredLogger(
    minimumLevel: .info,
    enableRedaction: true,
    applicationName: "MyWallet"
)

let metrics = EnhancedMetricsClient(
    enabled: true,
    batchSize: 100
)

let wallet = await CashuWallet(
    configuration: config,
    logger: logger,
    metrics: metrics
)

// Operations are automatically instrumented
try await wallet.mint(amount: 1000, paymentRequest: invoice)
// Logs: "Starting mint operation"
// Metrics: mint.start, mint.duration, mint.success
```

## Troubleshooting

### Debug Logging Output

```swift
// Enable debug output for StatsD
ProcessInfo.processInfo.environment["STATSD_DEBUG"] = "1"

// Enable console output for metrics
let metrics = ConsoleMetricsClient()
await metrics.setEnabled(true)
```

### Verify Secret Redaction

```swift
// Test redaction is working
let testLogger = StructuredLogger(
    enableRedaction: true,
    destination: .custom { log in
        assert(!log.contains("e7b5e4d6c3a2"), "Private key not redacted!")
        print(log)
    }
)
```

### Performance Monitoring

```swift
// Monitor metrics performance
let startTime = Date()
for _ in 0..<10000 {
    await metricsClient.increment("perf.test")
}
let duration = Date().timeIntervalSince(startTime)
print("10k metrics in \(duration)s")
```

## Security Considerations

1. **Always enable secret redaction in production**
2. **Never log authentication credentials**
3. **Sanitize user input before logging**
4. **Use secure transport for metric exports**
5. **Restrict access to log files and metrics endpoints**
6. **Regularly rotate log files**
7. **Monitor for sensitive data leaks**

## Conclusion

CoreCashu's observability features provide production-ready logging and metrics with built-in security through secret redaction. By following this guide and best practices, you can effectively monitor your Cashu wallet implementation while maintaining security and performance.