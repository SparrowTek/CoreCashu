import Testing
import Foundation
@testable import CoreCashu

@Suite("WebSocket Reconnection Strategy Tests", .serialized)
struct WebSocketReconnectionStrategyTests {

    @Suite("Exponential Backoff Strategy", .serialized)
    struct ExponentialBackoffTests {

        @Test("Initial delay calculation")
        func testInitialDelay() async throws {
            let strategy = ExponentialBackoffStrategy(
                configuration: .init(
                    initialDelay: 1.0,
                    maxDelay: 60.0,
                    multiplier: 2.0,
                    jitterFactor: 0.0 // No jitter for predictable testing
                )
            )

            let delay1 = await strategy.delay(for: 1, lastError: nil)
            #expect(delay1 == 1.0)

            let delay2 = await strategy.delay(for: 2, lastError: nil)
            #expect(delay2 == 2.0)

            let delay3 = await strategy.delay(for: 3, lastError: nil)
            #expect(delay3 == 4.0)
        }

        @Test("Max delay capping")
        func testMaxDelayCapping() async throws {
            let strategy = ExponentialBackoffStrategy(
                configuration: .init(
                    initialDelay: 1.0,
                    maxDelay: 5.0,
                    multiplier: 2.0,
                    jitterFactor: 0.0
                )
            )

            let delay10 = await strategy.delay(for: 10, lastError: nil)
            #expect(delay10 == 5.0) // Should be capped at maxDelay
        }

        @Test("Max attempts limit")
        func testMaxAttempts() async throws {
            let strategy = ExponentialBackoffStrategy(
                configuration: .init(
                    initialDelay: 1.0,
                    maxAttempts: 3,
                    jitterFactor: 0.0
                )
            )

            let delay1 = await strategy.delay(for: 1, lastError: nil)
            #expect(delay1 != nil)

            let delay3 = await strategy.delay(for: 3, lastError: nil)
            #expect(delay3 != nil)

            let delay4 = await strategy.delay(for: 4, lastError: nil)
            #expect(delay4 == nil) // Should return nil after max attempts
        }

        @Test("Jitter application")
        func testJitter() async throws {
            let strategy = ExponentialBackoffStrategy(
                configuration: .init(
                    initialDelay: 10.0,
                    jitterFactor: 0.2
                )
            )

            var delays: [TimeInterval] = []
            for _ in 0..<10 {
                if let delay = await strategy.delay(for: 1, lastError: nil) {
                    delays.append(delay)
                }
            }

            // With jitter, delays should vary within expected range
            let expectedBase = 10.0
            let jitterRange = 2.0 // 20% of 10.0

            for delay in delays {
                #expect(delay >= expectedBase - jitterRange)
                #expect(delay <= expectedBase + jitterRange)
            }

            // Not all delays should be exactly the same
            let uniqueDelays = Set(delays)
            #expect(uniqueDelays.count > 1)
        }

        @Test("Reset functionality")
        func testReset() async throws {
            let strategy = ExponentialBackoffStrategy(
                configuration: .init(
                    initialDelay: 1.0,
                    jitterFactor: 0.0
                )
            )

            // First sequence
            _ = await strategy.delay(for: 3, lastError: nil)

            // Reset
            await strategy.reset()

            // After reset, should start from initial delay again
            let delayAfterReset = await strategy.delay(for: 1, lastError: nil)
            #expect(delayAfterReset == 1.0)
        }

        @Test("Non-retryable errors")
        func testNonRetryableErrors() async throws {
            let strategy = ExponentialBackoffStrategy(
                configuration: .init(
                    nonRetryableErrors: [1002, 1003, 1008]
                )
            )

            // Should reconnect for general errors
            let shouldReconnectGeneral = await strategy.shouldReconnect(error: WebSocketError.connectionClosed)
            #expect(shouldReconnectGeneral == true)

            // Should not reconnect for timeout (not in non-retryable list)
            let shouldReconnectTimeout = await strategy.shouldReconnect(error: WebSocketError.timeout)
            #expect(shouldReconnectTimeout == true)
        }
    }

    @Suite("Fixed Interval Strategy", .serialized)
    struct FixedIntervalTests {

        @Test("Constant delay")
        func testConstantDelay() async throws {
            let strategy = FixedIntervalStrategy(interval: 5.0, maxAttempts: 10)

            for attempt in 1...10 {
                let delay = await strategy.delay(for: attempt, lastError: nil)
                #expect(delay == 5.0)
            }
        }

        @Test("Max attempts")
        func testMaxAttempts() async throws {
            let strategy = FixedIntervalStrategy(interval: 5.0, maxAttempts: 3)

            let delay1 = await strategy.delay(for: 1, lastError: nil)
            #expect(delay1 == 5.0)

            let delay3 = await strategy.delay(for: 3, lastError: nil)
            #expect(delay3 == 5.0)

            let delay4 = await strategy.delay(for: 4, lastError: nil)
            #expect(delay4 == nil)
        }

        @Test("Always reconnect")
        func testAlwaysReconnect() async throws {
            let strategy = FixedIntervalStrategy()

            let shouldReconnect = await strategy.shouldReconnect(error: WebSocketError.connectionFailed("test"))
            #expect(shouldReconnect == true)
        }
    }

    @Suite("No Reconnection Strategy", .serialized)
    struct NoReconnectionTests {

        @Test("No delay")
        func testNoDelay() async throws {
            let strategy = NoReconnectionStrategy()

            let delay = await strategy.delay(for: 1, lastError: nil)
            #expect(delay == nil)
        }

        @Test("Never reconnect")
        func testNeverReconnect() async throws {
            let strategy = NoReconnectionStrategy()

            let shouldReconnect = await strategy.shouldReconnect(error: nil)
            #expect(shouldReconnect == false)
        }
    }
}