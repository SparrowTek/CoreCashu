import Foundation

/// A no-operation WebSocket client for testing or when WebSocket functionality is not needed
/// This implementation does nothing and immediately returns success or throws predictable errors
public actor NoOpWebSocketClientProtocol: WebSocketClientProtocol {
    
    private var _isConnected = false
    private var shouldFailConnection = false
    private var shouldFailSend = false
    private var shouldFailReceive = false
    
    public var isConnected: Bool {
        _isConnected
    }
    
    public init(
        shouldFailConnection: Bool = false,
        shouldFailSend: Bool = false,
        shouldFailReceive: Bool = false
    ) {
        self.shouldFailConnection = shouldFailConnection
        self.shouldFailSend = shouldFailSend
        self.shouldFailReceive = shouldFailReceive
    }
    
    public func connect(to url: URL) async throws {
        guard !shouldFailConnection else {
            throw WebSocketError.connectionFailed("NoOp client configured to fail connections")
        }
        _isConnected = true
    }
    
    public func send(text: String) async throws {
        guard _isConnected else {
            throw WebSocketError.notConnected
        }
        guard !shouldFailSend else {
            throw WebSocketError.sendFailed("NoOp client configured to fail sends")
        }
        // Do nothing - message sent to the void
    }
    
    public func send(data: Data) async throws {
        guard _isConnected else {
            throw WebSocketError.notConnected
        }
        guard !shouldFailSend else {
            throw WebSocketError.sendFailed("NoOp client configured to fail sends")
        }
        // Do nothing - data sent to the void
    }
    
    public func receive() async throws -> WebSocketMessage {
        guard _isConnected else {
            throw WebSocketError.notConnected
        }
        guard !shouldFailReceive else {
            throw WebSocketError.receiveFailed("NoOp client configured to fail receives")
        }
        // Return empty message after a small delay to simulate network
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
        return .text("{\"status\":\"ok\"}")
    }
    
    public func ping() async throws {
        guard _isConnected else {
            throw WebSocketError.notConnected
        }
        // Do nothing - ping successful
    }
    
    public func close(code: WebSocketCloseCode, reason: Data?) async throws {
        _isConnected = false
    }
    
    public func disconnect() async {
        _isConnected = false
    }
}

/// A no-operation WebSocket client provider
public struct NoOpWebSocketClientProtocolProvider: WebSocketClientProtocolProvider {
    
    private let shouldFailConnection: Bool
    private let shouldFailSend: Bool
    private let shouldFailReceive: Bool
    
    public init(
        shouldFailConnection: Bool = false,
        shouldFailSend: Bool = false,
        shouldFailReceive: Bool = false
    ) {
        self.shouldFailConnection = shouldFailConnection
        self.shouldFailSend = shouldFailSend
        self.shouldFailReceive = shouldFailReceive
    }
    
    public func createClient() -> any WebSocketClientProtocol {
        NoOpWebSocketClientProtocol(
            shouldFailConnection: shouldFailConnection,
            shouldFailSend: shouldFailSend,
            shouldFailReceive: shouldFailReceive
        )
    }
    
    public func createClient(configuration: WebSocketConfiguration) -> any WebSocketClientProtocol {
        // Configuration is ignored for NoOp client
        createClient()
    }
}

// MARK: - Mock WebSocket Client for Testing

/// A mock WebSocket client that can be configured with predefined responses
public actor MockWebSocketClientProtocol: WebSocketClientProtocol {
    
    private var _isConnected = false
    private var messageQueue: [WebSocketMessage] = []
    private var receivedMessages: [String] = []
    private var receivedData: [Data] = []
    
    public var isConnected: Bool {
        _isConnected
    }
    
    /// Messages that were sent to this client (for test verification)
    public var sentTextMessages: [String] {
        receivedMessages
    }
    
    /// Data that was sent to this client (for test verification)
    public var sentDataMessages: [Data] {
        receivedData
    }
    
    public init() {}
    
    /// Queue a message to be returned by receive()
    public func queueMessage(_ message: WebSocketMessage) {
        messageQueue.append(message)
    }
    
    /// Queue multiple messages
    public func queueMessages(_ messages: [WebSocketMessage]) {
        messageQueue.append(contentsOf: messages)
    }
    
    /// Clear all queued messages
    public func clearMessageQueue() {
        messageQueue.removeAll()
    }
    
    /// Clear recorded sent messages
    public func clearSentMessages() {
        receivedMessages.removeAll()
        receivedData.removeAll()
    }
    
    public func connect(to url: URL) async throws {
        _isConnected = true
    }
    
    public func send(text: String) async throws {
        guard _isConnected else {
            throw WebSocketError.notConnected
        }
        receivedMessages.append(text)
    }
    
    public func send(data: Data) async throws {
        guard _isConnected else {
            throw WebSocketError.notConnected
        }
        receivedData.append(data)
    }
    
    public func receive() async throws -> WebSocketMessage {
        guard _isConnected else {
            throw WebSocketError.notConnected
        }
        
        guard !messageQueue.isEmpty else {
            // If no messages queued, wait indefinitely or timeout
            try await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
            throw WebSocketError.timeout
        }
        
        return messageQueue.removeFirst()
    }
    
    public func ping() async throws {
        guard _isConnected else {
            throw WebSocketError.notConnected
        }
    }
    
    public func close(code: WebSocketCloseCode, reason: Data?) async throws {
        _isConnected = false
    }
    
    public func disconnect() async {
        _isConnected = false
        messageQueue.removeAll()
    }
}

/// A mock WebSocket client provider for testing
public struct MockWebSocketClientProtocolProvider: WebSocketClientProtocolProvider {
    
    private let client: MockWebSocketClientProtocol
    
    public init(client: MockWebSocketClientProtocol = MockWebSocketClientProtocol()) {
        self.client = client
    }
    
    public func createClient() -> any WebSocketClientProtocol {
        client
    }
    
    public func createClient(configuration: WebSocketConfiguration) -> any WebSocketClientProtocol {
        client
    }
}