import Foundation

/// A robust WebSocket client with automatic reconnection, heartbeat, and backpressure handling
public actor RobustWebSocketClient: WebSocketClientProtocol {

    /// Connection state
    public enum ConnectionState: Sendable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)
        case disconnecting
    }

    /// Configuration for robust WebSocket client
    public struct RobustConfiguration: Sendable {
        /// Base WebSocket configuration
        public let webSocketConfig: WebSocketConfiguration

        /// Reconnection strategy
        public let reconnectionStrategy: any WebSocketReconnectionStrategy

        /// Message queue configuration
        public let queueConfig: WebSocketMessageQueue.Configuration

        /// Whether to queue messages while disconnected
        public let queueWhileDisconnected: Bool

        /// Heartbeat interval (0 to disable)
        public let heartbeatInterval: TimeInterval

        /// Connection timeout
        public let connectionTimeout: TimeInterval

        /// Maximum consecutive heartbeat failures before reconnecting
        public let maxHeartbeatFailures: Int

        public init(
            webSocketConfig: WebSocketConfiguration = WebSocketConfiguration(),
            reconnectionStrategy: any WebSocketReconnectionStrategy = ExponentialBackoffStrategy(),
            queueConfig: WebSocketMessageQueue.Configuration = WebSocketMessageQueue.Configuration(),
            queueWhileDisconnected: Bool = true,
            heartbeatInterval: TimeInterval = 30,
            connectionTimeout: TimeInterval = 30,
            maxHeartbeatFailures: Int = 3
        ) {
            self.webSocketConfig = webSocketConfig
            self.reconnectionStrategy = reconnectionStrategy
            self.queueConfig = queueConfig
            self.queueWhileDisconnected = queueWhileDisconnected
            self.heartbeatInterval = heartbeatInterval
            self.connectionTimeout = connectionTimeout
            self.maxHeartbeatFailures = maxHeartbeatFailures
        }
    }

    // MARK: - Properties

    private let underlyingClient: any WebSocketClientProtocol
    private let configuration: RobustConfiguration
    private let messageQueue: WebSocketMessageQueue
    private var connectionState: ConnectionState = .disconnected
    private var currentURL: URL?
    private var reconnectionTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var messageSendingTask: Task<Void, Never>?
    private var receiveHandlers: [(WebSocketMessage) async -> Void] = []
    private var consecutiveHeartbeatFailures = 0
    private let stateChangeHandlers = AsyncStream<ConnectionState>.makeStream()

    // MARK: - Initialization

    public init(
        client: any WebSocketClientProtocol,
        configuration: RobustConfiguration = RobustConfiguration()
    ) {
        self.underlyingClient = client
        self.configuration = configuration
        self.messageQueue = WebSocketMessageQueue(configuration: configuration.queueConfig)
    }

    deinit {
        reconnectionTask?.cancel()
        heartbeatTask?.cancel()
        messageSendingTask?.cancel()
    }

    // MARK: - WebSocketClientProtocol Implementation

    public var isConnected: Bool {
        switch connectionState {
        case .connected:
            return true
        default:
            return false
        }
    }

    public func connect(to url: URL) async throws {
        guard url.scheme == "ws" || url.scheme == "wss" else {
            throw WebSocketError.invalidURL
        }

        // Cancel any ongoing reconnection
        reconnectionTask?.cancel()
        reconnectionTask = nil

        currentURL = url
        connectionState = .connecting

        do {
            // Attempt connection with timeout
            try await withTimeout(seconds: configuration.connectionTimeout) { [weak self] in
                guard let self = self else { throw WebSocketError.connectionFailed("Client deallocated") }
                try await self.underlyingClient.connect(to: url)
            }

            connectionState = .connected
            await configuration.reconnectionStrategy.reset()
            consecutiveHeartbeatFailures = 0

            // Start background tasks
            startHeartbeat()
            startMessageSending()

            // Notify state change
            stateChangeHandlers.continuation.yield(.connected)

        } catch {
            connectionState = .disconnected

            // Check if we should attempt reconnection
            if await configuration.reconnectionStrategy.shouldReconnect(error: error) {
                startReconnection()
            }

            throw error
        }
    }

    public func send(text: String) async throws {
        let message = WebSocketMessage.text(text)
        try await sendMessage(message)
    }

    public func send(data: Data) async throws {
        let message = WebSocketMessage.data(data)
        try await sendMessage(message)
    }

    public func receive() async throws -> WebSocketMessage {
        guard isConnected else {
            throw WebSocketError.notConnected
        }

        do {
            let message = try await underlyingClient.receive()

            // Process received message through handlers
            for handler in receiveHandlers {
                await handler(message)
            }

            return message
        } catch {
            // Handle connection errors by triggering reconnection
            if await configuration.reconnectionStrategy.shouldReconnect(error: error) {
                startReconnection()
            }
            throw error
        }
    }

    public func ping() async throws {
        guard isConnected else {
            throw WebSocketError.notConnected
        }

        do {
            try await underlyingClient.ping()
            consecutiveHeartbeatFailures = 0
        } catch {
            consecutiveHeartbeatFailures += 1

            if consecutiveHeartbeatFailures >= configuration.maxHeartbeatFailures {
                // Too many failures, trigger reconnection
                startReconnection()
            }

            throw error
        }
    }

    public func close(code: WebSocketCloseCode, reason: Data?) async throws {
        connectionState = .disconnecting

        // Cancel background tasks
        reconnectionTask?.cancel()
        heartbeatTask?.cancel()
        messageSendingTask?.cancel()

        // Close underlying connection
        try await underlyingClient.close(code: code, reason: reason)

        connectionState = .disconnected
        currentURL = nil

        // Clear message queue if not queuing while disconnected
        if !configuration.queueWhileDisconnected {
            await messageQueue.clear()
        }
    }

    public func disconnect() async {
        connectionState = .disconnecting

        // Cancel all tasks
        reconnectionTask?.cancel()
        heartbeatTask?.cancel()
        messageSendingTask?.cancel()

        // Disconnect underlying client
        await underlyingClient.disconnect()

        connectionState = .disconnected
        currentURL = nil

        // Clear queue if configured
        if !configuration.queueWhileDisconnected {
            await messageQueue.clear()
        }
    }

    // MARK: - Public Methods

    /// Add a handler for received messages
    public func addReceiveHandler(_ handler: @escaping (WebSocketMessage) async -> Void) {
        receiveHandlers.append(handler)
    }

    /// Get the current connection state
    public func getConnectionState() -> ConnectionState {
        connectionState
    }

    /// Get queue statistics
    public func getQueueStatistics() async -> QueueStatistics {
        await messageQueue.statistics()
    }

    /// Subscribe to connection state changes
    public var stateChanges: AsyncStream<ConnectionState> {
        stateChangeHandlers.stream
    }

    /// Force a reconnection
    public func forceReconnect() {
        switch connectionState {
        case .connected, .reconnecting:
            startReconnection()
        default:
            break
        }
    }

    // MARK: - Private Methods

    private func sendMessage(_ message: WebSocketMessage) async throws {
        if isConnected {
            // Try to send directly
            do {
                switch message {
                case .text(let text):
                    try await underlyingClient.send(text: text)
                case .data(let data):
                    try await underlyingClient.send(data: data)
                }
            } catch {
                // Failed to send, queue for retry
                if configuration.queueWhileDisconnected {
                    await messageQueue.enqueue(message, priority: .normal)
                }

                // Check if we should reconnect
                if await configuration.reconnectionStrategy.shouldReconnect(error: error) {
                    startReconnection()
                }

                throw error
            }
        } else if configuration.queueWhileDisconnected {
            // Queue message for later delivery
            let enqueued = await messageQueue.enqueue(message, priority: .normal)
            if !enqueued {
                throw WebSocketError.sendFailed("Message queue is full")
            }
        } else {
            throw WebSocketError.notConnected
        }
    }

    private func startReconnection() {
        guard reconnectionTask == nil || reconnectionTask?.isCancelled == true else {
            return // Already reconnecting
        }

        connectionState = .reconnecting(attempt: 0)

        reconnectionTask = Task {
            var attempt = 0

            while !Task.isCancelled {
                attempt += 1
                connectionState = .reconnecting(attempt: attempt)
                stateChangeHandlers.continuation.yield(.reconnecting(attempt: attempt))

                // Calculate delay
                guard let delay = await configuration.reconnectionStrategy.delay(for: attempt, lastError: nil) else {
                    // No more retries
                    connectionState = .disconnected
                    stateChangeHandlers.continuation.yield(.disconnected)
                    break
                }

                // Wait before reconnecting
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                guard !Task.isCancelled else { break }

                // Attempt reconnection
                if let url = currentURL {
                    do {
                        try await withTimeout(seconds: configuration.connectionTimeout) { [weak self] in
                            guard let self = self else { throw WebSocketError.connectionFailed("Client deallocated") }
                            try await self.underlyingClient.connect(to: url)
                        }

                        // Success!
                        connectionState = .connected
                        await configuration.reconnectionStrategy.reset()
                        consecutiveHeartbeatFailures = 0

                        // Restart background tasks
                        startHeartbeat()
                        startMessageSending()

                        stateChangeHandlers.continuation.yield(.connected)
                        break

                    } catch {
                        // Failed, will retry
                        continue
                    }
                }
            }

            reconnectionTask = nil
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()

        guard configuration.heartbeatInterval > 0 else { return }

        heartbeatTask = Task {
            while !Task.isCancelled && isConnected {
                try? await Task.sleep(nanoseconds: UInt64(configuration.heartbeatInterval * 1_000_000_000))

                guard !Task.isCancelled && isConnected else { break }

                do {
                    try await ping()
                } catch {
                    // Ping failed, handled in ping() method
                }
            }
        }
    }

    private func startMessageSending() {
        messageSendingTask?.cancel()

        messageSendingTask = Task {
            while !Task.isCancelled && isConnected {
                // Check for queued messages
                if let queuedMessage = await messageQueue.dequeue() {
                    do {
                        switch queuedMessage.message {
                        case .text(let text):
                            try await underlyingClient.send(text: text)
                        case .data(let data):
                            try await underlyingClient.send(data: data)
                        }
                    } catch {
                        // Failed to send, requeue if possible
                        await messageQueue.requeue(queuedMessage)

                        // Brief pause before retrying
                        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
                    }
                } else {
                    // No messages, wait a bit
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
                }
            }
        }
    }

    private func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            // Add the operation task
            group.addTask {
                try await operation()
            }

            // Add timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw WebSocketError.timeout
            }

            // Return first to complete, cancel the other
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

/// Provider for creating robust WebSocket clients
public struct RobustWebSocketClientProvider: WebSocketClientProtocolProvider {

    private let underlyingProvider: any WebSocketClientProtocolProvider
    private let robustConfiguration: RobustWebSocketClient.RobustConfiguration

    public init(
        underlyingProvider: any WebSocketClientProtocolProvider,
        robustConfiguration: RobustWebSocketClient.RobustConfiguration = .init()
    ) {
        self.underlyingProvider = underlyingProvider
        self.robustConfiguration = robustConfiguration
    }

    public func createClient() -> any WebSocketClientProtocol {
        let underlyingClient = underlyingProvider.createClient()
        return RobustWebSocketClient(
            client: underlyingClient,
            configuration: robustConfiguration
        )
    }

    public func createClient(configuration: WebSocketConfiguration) -> any WebSocketClientProtocol {
        let underlyingClient = underlyingProvider.createClient(configuration: configuration)
        var robustConfig = robustConfiguration
        // Use the provided WebSocket configuration
        robustConfig = RobustWebSocketClient.RobustConfiguration(
            webSocketConfig: configuration,
            reconnectionStrategy: robustConfig.reconnectionStrategy,
            queueConfig: robustConfig.queueConfig,
            queueWhileDisconnected: robustConfig.queueWhileDisconnected,
            heartbeatInterval: robustConfig.heartbeatInterval,
            connectionTimeout: robustConfig.connectionTimeout,
            maxHeartbeatFailures: robustConfig.maxHeartbeatFailures
        )
        return RobustWebSocketClient(
            client: underlyingClient,
            configuration: robustConfig
        )
    }
}