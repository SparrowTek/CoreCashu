import Testing
import Foundation
@testable import CoreCashu

@Suite("Robust WebSocket Client Tests", .serialized)
struct RobustWebSocketClientTests {

    @Test("Basic connection and disconnection")
    func testBasicConnection() async throws {
        let mockClient = MockWebSocketClientProtocol()
        let robustClient = RobustWebSocketClient(client: mockClient)

        // Connect
        try await robustClient.connect(to: URL(string: "ws://example.com")!)
        let isConnected = await robustClient.isConnected
        #expect(isConnected == true)

        // Disconnect
        await robustClient.disconnect()
        let isDisconnected = await robustClient.isConnected
        #expect(isDisconnected == false)
    }

    @Test("Send and receive messages")
    func testSendReceive() async throws {
        let mockClient = MockWebSocketClientProtocol()
        let robustClient = RobustWebSocketClient(client: mockClient)

        // Connect
        try await robustClient.connect(to: URL(string: "ws://example.com")!)

        // Send text message
        try await robustClient.send(text: "test message")
        let sentMessages = await mockClient.sentTextMessages
        #expect(sentMessages.contains("test message"))

        // Queue receive message
        await mockClient.queueMessage(.text("response"))

        // Receive message
        let received = try await robustClient.receive()
        if case .text(let text) = received {
            #expect(text == "response")
        } else {
            Issue.record("Expected text message")
        }
    }

    @Test("Message queuing while disconnected")
    func testQueueWhileDisconnected() async throws {
        let mockClient = MockWebSocketClientProtocol()
        let config = RobustWebSocketClient.RobustConfiguration(
            queueWhileDisconnected: true
        )
        let robustClient = RobustWebSocketClient(
            client: mockClient,
            configuration: config
        )

        // Send while disconnected - should queue without error
        try await robustClient.send(text: "queued message")

        // Check queue statistics
        let stats = await robustClient.getQueueStatistics()
        #expect(stats.queuedMessages == 1)

        // Connect - queued message should be sent
        try await robustClient.connect(to: URL(string: "ws://example.com")!)

        // Wait for message to be sent
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms

        let sentMessages = await mockClient.sentTextMessages
        #expect(sentMessages.contains("queued message"))
    }

    @Test("Automatic reconnection")
    func testAutomaticReconnection() async throws {
        let mockClient = SimulatedDisconnectClient()
        let reconnectStrategy = FixedIntervalStrategy(interval: 0.1, maxAttempts: 3)
        let config = RobustWebSocketClient.RobustConfiguration(
            reconnectionStrategy: reconnectStrategy,
            heartbeatInterval: 0.05, // Enable heartbeat to detect disconnection
            maxHeartbeatFailures: 1
        )
        let robustClient = RobustWebSocketClient(
            client: mockClient,
            configuration: config
        )

        // Track state changes
        let stateTracker = StateTracker()
        let stateTask = Task {
            for await state in await robustClient.stateChanges {
                await stateTracker.addState(state)
                if case .connected = state, await stateTracker.count() > 1 {
                    break // Reconnected
                }
            }
        }

        // Connect
        try await robustClient.connect(to: URL(string: "ws://example.com")!)

        // Wait a moment for connection to stabilize
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Simulate disconnection
        await mockClient.simulateDisconnect()

        // Wait for heartbeat to detect disconnection and trigger reconnection
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        stateTask.cancel()

        // Check that we went through reconnection states
        let hasReconnecting = await stateTracker.hasReconnecting()
        #expect(hasReconnecting)

        // Should be connected again
        let finalConnected = await mockClient.isConnected
        #expect(finalConnected == true)
    }

    @Test("Heartbeat mechanism")
    func testHeartbeat() async throws {
        let mockClient = PingTrackingClient()
        let config = RobustWebSocketClient.RobustConfiguration(
            heartbeatInterval: 0.1, // 100ms heartbeat
            maxHeartbeatFailures: 3
        )
        let robustClient = RobustWebSocketClient(
            client: mockClient,
            configuration: config
        )

        // Connect
        try await robustClient.connect(to: URL(string: "ws://example.com")!)

        // Wait for heartbeats
        try await Task.sleep(nanoseconds: 350_000_000) // 350ms

        // Should have sent at least 3 pings
        let pingCount = await mockClient.pingCount
        #expect(pingCount >= 3)
    }

    @Test("Heartbeat failure triggers reconnection")
    func testHeartbeatFailureReconnection() async throws {
        let mockClient = FailingPingClient()
        let reconnectStrategy = FixedIntervalStrategy(interval: 0.1, maxAttempts: 3)
        let config = RobustWebSocketClient.RobustConfiguration(
            reconnectionStrategy: reconnectStrategy,
            heartbeatInterval: 0.1,
            maxHeartbeatFailures: 2
        )
        let robustClient = RobustWebSocketClient(
            client: mockClient,
            configuration: config
        )

        // Track state changes
        let reconnectTracker = ReconnectTracker()
        let stateTask = Task {
            for await state in await robustClient.stateChanges {
                if case .reconnecting = state {
                    await reconnectTracker.setHasReconnecting(true)
                    break
                }
            }
        }

        // Connect
        try await robustClient.connect(to: URL(string: "ws://example.com")!)

        // Wait for heartbeat failures to trigger reconnection
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        stateTask.cancel()

        // Should have triggered reconnection
        let hasReconnecting = await reconnectTracker.hasReconnecting
        #expect(hasReconnecting)
    }

    @Test("Backpressure handling")
    func testBackpressure() async throws {
        let mockClient = DisconnectedClient()  // Use a disconnected client to force queuing
        let config = RobustWebSocketClient.RobustConfiguration(
            queueConfig: .init(
                maxQueueSize: 3,
                dropOldestWhenFull: true
            ),
            queueWhileDisconnected: true
        )
        let robustClient = RobustWebSocketClient(
            client: mockClient,
            configuration: config
        )

        // Send multiple messages quickly while disconnected - they will all queue
        for i in 0..<10 {
            try await robustClient.send(text: "message\(i)")
        }

        // Check queue statistics
        let stats = await robustClient.getQueueStatistics()
        #expect(stats.queuedMessages <= 3) // Queue size is limited to 3
        #expect(stats.droppedMessages >= 7) // At least 7 messages should have been dropped
    }

    @Test("Connection timeout")
    func testConnectionTimeout() async throws {
        let mockClient = TimeoutClient()
        let config = RobustWebSocketClient.RobustConfiguration(
            connectionTimeout: 0.1 // 100ms timeout
        )
        let robustClient = RobustWebSocketClient(
            client: mockClient,
            configuration: config
        )

        // Connect should timeout
        do {
            try await robustClient.connect(to: URL(string: "ws://example.com")!)
            Issue.record("Should have timed out")
        } catch {
            if case WebSocketError.timeout = error {
                // Expected
            } else {
                Issue.record("Expected timeout error")
            }
        }
    }

    @Test("Force reconnect")
    func testForceReconnect() async throws {
        let mockClient = MockWebSocketClientProtocol()
        let config = RobustWebSocketClient.RobustConfiguration(
            reconnectionStrategy: FixedIntervalStrategy(interval: 0.1),
            heartbeatInterval: 0
        )
        let robustClient = RobustWebSocketClient(
            client: mockClient,
            configuration: config
        )

        // Connect
        try await robustClient.connect(to: URL(string: "ws://example.com")!)

        // Track state changes
        let reconnectTracker = ReconnectTracker()
        let stateTask = Task {
            for await state in await robustClient.stateChanges {
                if case .reconnecting = state {
                    await reconnectTracker.setHasReconnecting(true)
                    break
                }
            }
        }

        // Force reconnect
        await robustClient.forceReconnect()

        // Wait a bit
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms

        stateTask.cancel()

        let hasReconnecting = await reconnectTracker.hasReconnecting
        #expect(hasReconnecting)
    }

    @Test("Receive handler")
    func testReceiveHandler() async throws {
        let mockClient = MockWebSocketClientProtocol()
        let robustClient = RobustWebSocketClient(client: mockClient)

        let messageCollector = MessageCollector()
        await robustClient.addReceiveHandler { message in
            if case .text(let text) = message {
                await messageCollector.addMessage(text)
            }
        }

        // Connect
        try await robustClient.connect(to: URL(string: "ws://example.com")!)

        // Queue and receive messages
        await mockClient.queueMessage(.text("message1"))
        await mockClient.queueMessage(.text("message2"))

        _ = try await robustClient.receive()
        _ = try await robustClient.receive()

        let messages = await messageCollector.messages
        #expect(messages == ["message1", "message2"])
    }

    @Test("Close with code and reason")
    func testCloseWithCodeAndReason() async throws {
        let mockClient = MockWebSocketClientProtocol()
        let robustClient = RobustWebSocketClient(client: mockClient)

        // Connect
        try await robustClient.connect(to: URL(string: "ws://example.com")!)

        // Close with specific code
        try await robustClient.close(
            code: .normalClosure,
            reason: "Test closure".data(using: .utf8)
        )

        let isConnected = await robustClient.isConnected
        #expect(isConnected == false)
    }

    @Test("Invalid URL")
    func testInvalidURL() async throws {
        let mockClient = MockWebSocketClientProtocol()
        let robustClient = RobustWebSocketClient(client: mockClient)

        // Try to connect with invalid scheme
        do {
            try await robustClient.connect(to: URL(string: "http://example.com")!)
            Issue.record("Should have thrown invalid URL error")
        } catch {
            if case WebSocketError.invalidURL = error {
                // Expected
            } else {
                Issue.record("Expected invalid URL error")
            }
        }
    }
}

// MARK: - Mock Clients for Testing

/// Client that is always disconnected
actor DisconnectedClient: WebSocketClientProtocol {
    var isConnected: Bool { false }

    func connect(to url: URL) async throws {
        // Never connects
        throw WebSocketError.connectionFailed("Mock client always disconnected")
    }

    func send(text: String) async throws {
        throw WebSocketError.notConnected
    }

    func send(data: Data) async throws {
        throw WebSocketError.notConnected
    }

    func receive() async throws -> WebSocketMessage {
        throw WebSocketError.notConnected
    }

    func ping() async throws {
        throw WebSocketError.notConnected
    }

    func close(code: WebSocketCloseCode, reason: Data?) async throws {
        // Already disconnected
    }

    func disconnect() async {
        // Already disconnected
    }
}

/// Client that simulates disconnection and supports reconnection
actor SimulatedDisconnectClient: WebSocketClientProtocol {
    private var _isConnected = false
    private var disconnectSimulated = false

    var isConnected: Bool { _isConnected }

    func connect(to url: URL) async throws {
        // Simulate reconnection working after disconnect
        if disconnectSimulated {
            // Allow reconnection
            _isConnected = true
            disconnectSimulated = false
        } else {
            _isConnected = true
        }
    }

    func simulateDisconnect() {
        _isConnected = false
        disconnectSimulated = true
    }

    func send(text: String) async throws {
        guard _isConnected else { throw WebSocketError.notConnected }
    }

    func send(data: Data) async throws {
        guard _isConnected else { throw WebSocketError.notConnected }
    }

    func receive() async throws -> WebSocketMessage {
        guard _isConnected else { throw WebSocketError.connectionClosed }
        try await Task.sleep(nanoseconds: 100_000_000)
        return .text("test")
    }

    func ping() async throws {
        guard _isConnected else {
            throw WebSocketError.notConnected
        }
    }

    func close(code: WebSocketCloseCode, reason: Data?) async throws {
        _isConnected = false
    }

    func disconnect() async {
        _isConnected = false
    }
}

/// Client that tracks ping count
actor PingTrackingClient: WebSocketClientProtocol {
    private var _isConnected = false
    private(set) var pingCount = 0

    var isConnected: Bool { _isConnected }

    func connect(to url: URL) async throws {
        _isConnected = true
    }

    func send(text: String) async throws {
        guard _isConnected else { throw WebSocketError.notConnected }
    }

    func send(data: Data) async throws {
        guard _isConnected else { throw WebSocketError.notConnected }
    }

    func receive() async throws -> WebSocketMessage {
        guard _isConnected else { throw WebSocketError.notConnected }
        try await Task.sleep(nanoseconds: 100_000_000)
        return .text("test")
    }

    func ping() async throws {
        guard _isConnected else { throw WebSocketError.notConnected }
        pingCount += 1
    }

    func close(code: WebSocketCloseCode, reason: Data?) async throws {
        _isConnected = false
    }

    func disconnect() async {
        _isConnected = false
    }
}

/// Client where ping always fails
actor FailingPingClient: WebSocketClientProtocol {
    private var _isConnected = false

    var isConnected: Bool { _isConnected }

    func connect(to url: URL) async throws {
        _isConnected = true
    }

    func send(text: String) async throws {
        guard _isConnected else { throw WebSocketError.notConnected }
    }

    func send(data: Data) async throws {
        guard _isConnected else { throw WebSocketError.notConnected }
    }

    func receive() async throws -> WebSocketMessage {
        guard _isConnected else { throw WebSocketError.notConnected }
        try await Task.sleep(nanoseconds: 100_000_000)
        return .text("test")
    }

    func ping() async throws {
        throw WebSocketError.sendFailed("Ping failed")
    }

    func close(code: WebSocketCloseCode, reason: Data?) async throws {
        _isConnected = false
    }

    func disconnect() async {
        _isConnected = false
    }
}

/// Client that simulates slow sending
actor SlowSendingClient: WebSocketClientProtocol {
    private var _isConnected = false

    var isConnected: Bool { _isConnected }

    func connect(to url: URL) async throws {
        _isConnected = true
    }

    func send(text: String) async throws {
        guard _isConnected else { throw WebSocketError.notConnected }
        try await Task.sleep(nanoseconds: 100_000_000) // Slow send
    }

    func send(data: Data) async throws {
        guard _isConnected else { throw WebSocketError.notConnected }
        try await Task.sleep(nanoseconds: 100_000_000) // Slow send
    }

    func receive() async throws -> WebSocketMessage {
        guard _isConnected else { throw WebSocketError.notConnected }
        try await Task.sleep(nanoseconds: 100_000_000)
        return .text("test")
    }

    func ping() async throws {
        guard _isConnected else {
            throw WebSocketError.notConnected
        }
    }

    func close(code: WebSocketCloseCode, reason: Data?) async throws {
        _isConnected = false
    }

    func disconnect() async {
        _isConnected = false
    }
}

/// Client that times out on connection
actor TimeoutClient: WebSocketClientProtocol {
    private var _isConnected = false

    var isConnected: Bool { _isConnected }

    func connect(to url: URL) async throws {
        // Never completes
        try await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
        _isConnected = true
    }

    func send(text: String) async throws {
        guard _isConnected else { throw WebSocketError.notConnected }
    }

    func send(data: Data) async throws {
        guard _isConnected else { throw WebSocketError.notConnected }
    }

    func receive() async throws -> WebSocketMessage {
        guard _isConnected else { throw WebSocketError.notConnected }
        return .text("test")
    }

    func ping() async throws {
        guard _isConnected else {
            throw WebSocketError.notConnected
        }
    }

    func close(code: WebSocketCloseCode, reason: Data?) async throws {
        _isConnected = false
    }

    func disconnect() async {
        _isConnected = false
    }
}

// MARK: - Test Helper Actors

/// Actor for tracking state changes in tests
actor StateTracker {
    private var states: [RobustWebSocketClient.ConnectionState] = []

    func addState(_ state: RobustWebSocketClient.ConnectionState) {
        states.append(state)
    }

    func count() -> Int {
        states.count
    }

    func hasReconnecting() -> Bool {
        states.contains { state in
            if case .reconnecting = state { return true }
            return false
        }
    }
}

/// Actor for tracking reconnection state
actor ReconnectTracker {
    private var _hasReconnecting = false

    var hasReconnecting: Bool { _hasReconnecting }

    func setHasReconnecting(_ value: Bool) {
        _hasReconnecting = value
    }
}

/// Actor for collecting messages
actor MessageCollector {
    private var _messages: [String] = []

    var messages: [String] { _messages }

    func addMessage(_ message: String) {
        _messages.append(message)
    }
}