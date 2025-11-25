import Testing
import Foundation
@testable import CoreCashu

@Suite("WebSocket Message Queue Tests", .serialized)
struct WebSocketMessageQueueTests {

    @Test("Basic enqueue and dequeue")
    func testBasicEnqueueDequeue() async throws {
        let queue = WebSocketMessageQueue()

        // Enqueue messages
        let result1 = await queue.enqueue(.text("message1"))
        #expect(result1 == true)

        let result2 = await queue.enqueue(.data(Data([0x01, 0x02])))
        #expect(result2 == true)

        // Check count
        let count = await queue.count
        #expect(count == 2)

        // Dequeue messages
        let message1 = await queue.dequeue()
        #expect(message1 != nil)
        if case .text(let text) = message1?.message {
            #expect(text == "message1")
        } else {
            Issue.record("Expected text message")
        }

        let message2 = await queue.dequeue()
        #expect(message2 != nil)
        if case .data(let data) = message2?.message {
            #expect(data == Data([0x01, 0x02]))
        } else {
            Issue.record("Expected data message")
        }

        // Queue should be empty
        let isEmpty = await queue.isEmpty
        #expect(isEmpty == true)
    }

    @Test("Priority ordering")
    func testPriorityOrdering() async throws {
        let queue = WebSocketMessageQueue()

        // Enqueue messages with different priorities
        await queue.enqueue(.text("low"), priority: .low)
        await queue.enqueue(.text("critical"), priority: .critical)
        await queue.enqueue(.text("normal"), priority: .normal)
        await queue.enqueue(.text("high"), priority: .high)

        // Should dequeue in priority order
        let message1 = await queue.dequeue()
        if case .text(let text) = message1?.message {
            #expect(text == "critical")
        }

        let message2 = await queue.dequeue()
        if case .text(let text) = message2?.message {
            #expect(text == "high")
        }

        let message3 = await queue.dequeue()
        if case .text(let text) = message3?.message {
            #expect(text == "normal")
        }

        let message4 = await queue.dequeue()
        if case .text(let text) = message4?.message {
            #expect(text == "low")
        }
    }

    @Test("Queue size limit")
    func testQueueSizeLimit() async throws {
        let queue = WebSocketMessageQueue(
            configuration: .init(
                maxQueueSize: 3,
                dropOldestWhenFull: true
            )
        )

        // Fill queue
        await queue.enqueue(.text("message1"), priority: .low)
        await queue.enqueue(.text("message2"), priority: .normal)
        await queue.enqueue(.text("message3"), priority: .high)

        // Add one more - should drop lowest priority
        let result = await queue.enqueue(.text("message4"), priority: .critical)
        #expect(result == true)

        // Check statistics
        let stats = await queue.statistics()
        #expect(stats.queuedMessages == 3)
        #expect(stats.droppedMessages == 1)

        // Verify the low priority message was dropped
        let message1 = await queue.dequeue()
        if case .text(let text) = message1?.message {
            #expect(text == "message4") // Critical priority
        }
    }

    @Test("Requeue with retry limit")
    func testRequeueWithRetryLimit() async throws {
        let queue = WebSocketMessageQueue()

        // Create a message with max retries of 2
        await queue.enqueue(.text("retry-message"), maxRetries: 2)

        // Dequeue and requeue multiple times
        if let message1 = await queue.dequeue() {
            #expect(message1.retryCount == 0)
            let requeued1 = await queue.requeue(message1)
            #expect(requeued1 == true)
        }

        if let message2 = await queue.dequeue() {
            #expect(message2.retryCount == 1)
            let requeued2 = await queue.requeue(message2)
            #expect(requeued2 == true)
        }

        if let message3 = await queue.dequeue() {
            #expect(message3.retryCount == 2)
            let requeued3 = await queue.requeue(message3)
            #expect(requeued3 == false) // Should fail - max retries exceeded
        }

        // Check dropped count
        let stats = await queue.statistics()
        #expect(stats.droppedMessages == 1)
    }

    @Test("Message TTL expiration")
    func testMessageTTL() async throws {
        let queue = WebSocketMessageQueue(
            configuration: .init(
                messageTTL: 0.1 // 100ms TTL
            )
        )

        // Add message
        await queue.enqueue(.text("expired-message"))

        // Wait for expiration
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms

        // Try to dequeue - should be empty due to expiration
        let message = await queue.dequeue()
        #expect(message == nil)

        // Check dropped count
        let stats = await queue.statistics()
        #expect(stats.droppedMessages == 1)
    }

    @Test("Memory limit")
    func testMemoryLimit() async throws {
        let queue = WebSocketMessageQueue(
            configuration: .init(
                dropOldestWhenFull: true,
                maxMemoryBytes: 200 // Very small limit
            )
        )

        // Create large messages
        let largeText = String(repeating: "x", count: 100)

        // Add messages
        await queue.enqueue(WebSocketMessage.text(largeText), priority: .low)
        await queue.enqueue(WebSocketMessage.text(largeText), priority: .normal)
        await queue.enqueue(WebSocketMessage.text(largeText), priority: .high) // Should drop low priority

        // Check that we're within memory limit
        let stats = await queue.statistics()
        #expect(stats.memoryUsage <= 200)
        #expect(stats.droppedMessages > 0)
    }

    @Test("Peek functionality")
    func testPeek() async throws {
        let queue = WebSocketMessageQueue()

        await queue.enqueue(.text("peek-message"))

        // Peek shouldn't remove the message
        let peeked = await queue.peek()
        #expect(peeked != nil)

        // Message should still be in queue
        let count = await queue.count
        #expect(count == 1)

        // Dequeue should return the same message
        let dequeued = await queue.dequeue()
        #expect(dequeued?.id == peeked?.id)
    }

    @Test("Clear queue")
    func testClear() async throws {
        let queue = WebSocketMessageQueue()

        // Add multiple messages
        for i in 0..<5 {
            await queue.enqueue(.text("message\(i)"))
        }

        // Clear all
        await queue.clear()

        // Should be empty
        let isEmpty = await queue.isEmpty
        #expect(isEmpty == true)

        let stats = await queue.statistics()
        #expect(stats.queuedMessages == 0)
        #expect(stats.memoryUsage == 0)
    }

    @Test("Statistics tracking")
    func testStatistics() async throws {
        let queue = WebSocketMessageQueue(
            configuration: .init(
                maxQueueSize: 2,
                dropOldestWhenFull: true
            )
        )

        // Add messages
        await queue.enqueue(.text("message1"))
        await queue.enqueue(.text("message2"))
        await queue.enqueue(.text("message3")) // Will drop oldest

        // Dequeue one
        _ = await queue.dequeue()

        // Check statistics
        let stats = await queue.statistics()
        #expect(stats.queuedMessages == 1)
        #expect(stats.droppedMessages == 1)
        #expect(stats.deliveredMessages == 1)
        #expect(stats.memoryUsage > 0)
        #expect(stats.oldestMessageAge != nil)
    }

    @Test("Concurrent operations")
    func testConcurrentOperations() async throws {
        let queue = WebSocketMessageQueue()

        // Concurrently enqueue and dequeue
        await withTaskGroup(of: Void.self) { group in
            // Enqueue tasks
            for i in 0..<10 {
                group.addTask {
                    await queue.enqueue(.text("message\(i)"))
                }
            }

            // Dequeue tasks
            for _ in 0..<5 {
                group.addTask {
                    _ = await queue.dequeue()
                }
            }
        }

        // Should have 5 messages left
        let count = await queue.count
        #expect(count == 5)
    }
}