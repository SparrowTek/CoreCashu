import Foundation

/// Queue for managing WebSocket message backpressure
public actor WebSocketMessageQueue {

    /// Message with priority and metadata
    public struct QueuedMessage: Sendable {
        public enum Priority: Int, Comparable, Sendable {
            case low = 0
            case normal = 1
            case high = 2
            case critical = 3

            public static func < (lhs: Priority, rhs: Priority) -> Bool {
                lhs.rawValue < rhs.rawValue
            }
        }

        public let id: UUID
        public let priority: Priority
        public let message: WebSocketMessage
        public let timestamp: Date
        public let retryCount: Int
        public let maxRetries: Int

        public init(
            message: WebSocketMessage,
            priority: Priority = .normal,
            maxRetries: Int = 3
        ) {
            self.id = UUID()
            self.priority = priority
            self.message = message
            self.timestamp = Date()
            self.retryCount = 0
            self.maxRetries = maxRetries
        }

        fileprivate init(from original: QueuedMessage, incrementRetry: Bool) {
            self.id = original.id
            self.priority = original.priority
            self.message = original.message
            self.timestamp = original.timestamp
            self.retryCount = incrementRetry ? original.retryCount + 1 : original.retryCount
            self.maxRetries = original.maxRetries
        }
    }

    /// Configuration for the message queue
    public struct Configuration: Sendable {
        /// Maximum number of messages to queue
        public let maxQueueSize: Int

        /// Time-to-live for messages in seconds (0 for no TTL)
        public let messageTTL: TimeInterval

        /// Whether to drop oldest messages when queue is full
        public let dropOldestWhenFull: Bool

        /// Maximum memory usage in bytes (0 for unlimited)
        public let maxMemoryBytes: Int

        public init(
            maxQueueSize: Int = 1000,
            messageTTL: TimeInterval = 300, // 5 minutes
            dropOldestWhenFull: Bool = true,
            maxMemoryBytes: Int = 10 * 1024 * 1024 // 10MB
        ) {
            self.maxQueueSize = maxQueueSize
            self.messageTTL = messageTTL
            self.dropOldestWhenFull = dropOldestWhenFull
            self.maxMemoryBytes = maxMemoryBytes
        }
    }

    private let configuration: Configuration
    private var queue: [QueuedMessage] = []
    private var currentMemoryUsage: Int = 0
    private var droppedMessageCount: Int = 0
    private var deliveredMessageCount: Int = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Enqueue a message
    /// - Parameters:
    ///   - message: The WebSocket message to enqueue
    ///   - priority: Message priority
    ///   - maxRetries: Maximum retry attempts
    /// - Returns: true if message was enqueued, false if dropped
    @discardableResult
    public func enqueue(
        _ message: WebSocketMessage,
        priority: QueuedMessage.Priority = .normal,
        maxRetries: Int = 3
    ) -> Bool {
        // Check TTL and remove expired messages first
        removeExpiredMessages()

        let queuedMessage = QueuedMessage(
            message: message,
            priority: priority,
            maxRetries: maxRetries
        )

        // Estimate memory usage
        let messageSize = estimateMessageSize(message)

        // Check queue size limit
        if queue.count >= configuration.maxQueueSize {
            if configuration.dropOldestWhenFull {
                // Drop the oldest low-priority message
                if let lowestPriorityIndex = findLowestPriorityIndex() {
                    let droppedMessage = queue.remove(at: lowestPriorityIndex)
                    currentMemoryUsage -= estimateMessageSize(droppedMessage.message)
                    droppedMessageCount += 1
                }
            } else {
                droppedMessageCount += 1
                return false
            }
        }

        // Check memory limit
        if configuration.maxMemoryBytes > 0 {
            while currentMemoryUsage + messageSize > configuration.maxMemoryBytes && !queue.isEmpty {
                if let lowestPriorityIndex = findLowestPriorityIndex() {
                    let droppedMessage = queue.remove(at: lowestPriorityIndex)
                    currentMemoryUsage -= estimateMessageSize(droppedMessage.message)
                    droppedMessageCount += 1
                } else {
                    break
                }
            }

            // Still over limit after dropping messages
            if currentMemoryUsage + messageSize > configuration.maxMemoryBytes {
                droppedMessageCount += 1
                return false
            }
        }

        // Add message to queue
        queue.append(queuedMessage)
        currentMemoryUsage += messageSize

        // Sort by priority and timestamp
        sortQueue()

        return true
    }

    /// Dequeue the highest priority message
    /// - Returns: The next message to send, or nil if queue is empty
    public func dequeue() -> QueuedMessage? {
        removeExpiredMessages()

        guard !queue.isEmpty else { return nil }

        let message = queue.removeFirst()
        currentMemoryUsage -= estimateMessageSize(message.message)
        deliveredMessageCount += 1

        return message
    }

    /// Requeue a message that failed to send
    /// - Parameter message: The message to requeue
    /// - Returns: true if message was requeued, false if max retries exceeded
    @discardableResult
    public func requeue(_ message: QueuedMessage) -> Bool {
        if message.retryCount >= message.maxRetries {
            droppedMessageCount += 1
            return false
        }

        let retriedMessage = QueuedMessage(from: message, incrementRetry: true)
        queue.insert(retriedMessage, at: 0) // Insert at front for immediate retry
        currentMemoryUsage += estimateMessageSize(retriedMessage.message)

        return true
    }

    /// Peek at the next message without removing it
    public func peek() -> QueuedMessage? {
        removeExpiredMessages()
        return queue.first
    }

    /// Clear all messages from the queue
    public func clear() {
        queue.removeAll()
        currentMemoryUsage = 0
    }

    /// Get current queue statistics
    public func statistics() -> QueueStatistics {
        QueueStatistics(
            queuedMessages: queue.count,
            droppedMessages: droppedMessageCount,
            deliveredMessages: deliveredMessageCount,
            memoryUsage: currentMemoryUsage,
            oldestMessageAge: oldestMessageAge()
        )
    }

    /// Check if the queue is empty
    public var isEmpty: Bool {
        removeExpiredMessages()
        return queue.isEmpty
    }

    /// Current number of messages in queue
    public var count: Int {
        queue.count
    }

    // MARK: - Private Methods

    private func removeExpiredMessages() {
        guard configuration.messageTTL > 0 else { return }

        let now = Date()
        let originalCount = queue.count

        queue.removeAll { message in
            let age = now.timeIntervalSince(message.timestamp)
            let expired = age > configuration.messageTTL
            if expired {
                currentMemoryUsage -= estimateMessageSize(message.message)
            }
            return expired
        }

        let removedCount = originalCount - queue.count
        if removedCount > 0 {
            droppedMessageCount += removedCount
        }
    }

    private func sortQueue() {
        queue.sort { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority > rhs.priority
            }
            return lhs.timestamp < rhs.timestamp
        }
    }

    private func findLowestPriorityIndex() -> Int? {
        guard !queue.isEmpty else { return nil }

        var lowestIndex = 0
        var lowestPriority = queue[0].priority

        for (index, message) in queue.enumerated().dropFirst() {
            if message.priority < lowestPriority {
                lowestPriority = message.priority
                lowestIndex = index
            }
        }

        return lowestIndex
    }

    private func estimateMessageSize(_ message: WebSocketMessage) -> Int {
        switch message {
        case .text(let string):
            return string.utf8.count + 64 // String content + overhead
        case .data(let data):
            return data.count + 64 // Data content + overhead
        }
    }

    private func oldestMessageAge() -> TimeInterval? {
        guard let oldestMessage = queue.last else { return nil }
        return Date().timeIntervalSince(oldestMessage.timestamp)
    }
}

/// Statistics for the message queue
public struct QueueStatistics: Sendable {
    public let queuedMessages: Int
    public let droppedMessages: Int
    public let deliveredMessages: Int
    public let memoryUsage: Int
    public let oldestMessageAge: TimeInterval?
}