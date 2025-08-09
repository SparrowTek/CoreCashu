import Foundation

/// Protocol for WebSocket client operations used in Cashu (NUT-17)
/// Implementations can use URLSessionWebSocketTask (Apple) or NIO WebSockets (Linux)
public protocol WebSocketClientProtocol: Sendable {
    
    /// Connection state of the WebSocket
    var isConnected: Bool { get async }
    
    /// Connect to a WebSocket endpoint
    /// - Parameter url: The WebSocket URL (ws:// or wss://)
    /// - Throws: An error if the connection fails
    func connect(to url: URL) async throws
    
    /// Send text message through the WebSocket
    /// - Parameter text: The text message to send
    /// - Throws: An error if sending fails
    func send(text: String) async throws
    
    /// Send binary data through the WebSocket
    /// - Parameter data: The binary data to send
    /// - Throws: An error if sending fails
    func send(data: Data) async throws
    
    /// Receive a message from the WebSocket
    /// - Returns: The received message
    /// - Throws: An error if receiving fails or connection is closed
    func receive() async throws -> WebSocketMessage
    
    /// Send a ping to keep the connection alive
    /// - Throws: An error if ping fails
    func ping() async throws
    
    /// Close the WebSocket connection
    /// - Parameters:
    ///   - code: The close code (default: normalClosure)
    ///   - reason: Optional reason for closing
    /// - Throws: An error if closing fails
    func close(code: WebSocketCloseCode, reason: Data?) async throws
    
    /// Disconnect and cleanup resources
    func disconnect() async
}

/// Message types that can be received from a WebSocket
public enum WebSocketMessage: Sendable {
    case text(String)
    case data(Data)
}

/// WebSocket close codes
public enum WebSocketCloseCode: Int, Sendable {
    case normalClosure = 1000
    case goingAway = 1001
    case protocolError = 1002
    case unsupportedData = 1003
    case noStatusReceived = 1005
    case abnormalClosure = 1006
    case invalidFramePayloadData = 1007
    case policyViolation = 1008
    case messageTooBig = 1009
    case mandatoryExtensionMissing = 1010
    case internalServerError = 1011
    case tlsHandshakeFailure = 1015
}

/// Protocol for creating WebSocket clients
/// This allows dependency injection of platform-specific implementations
public protocol WebSocketClientProtocolProvider: Sendable {
    /// Create a new WebSocket client instance
    /// - Returns: A WebSocket client implementation
    func createClient() -> any WebSocketClientProtocol
    
    /// Create a WebSocket client with configuration
    /// - Parameter configuration: Configuration for the WebSocket client
    /// - Returns: A configured WebSocket client implementation
    func createClient(configuration: WebSocketConfiguration) -> any WebSocketClientProtocol
}

/// Configuration for WebSocket connections
public struct WebSocketConfiguration: Sendable {
    /// Maximum frame size in bytes
    public let maxFrameSize: Int
    
    /// Enable compression
    public let enableCompression: Bool
    
    /// Timeout for connection attempts in seconds
    public let connectionTimeout: TimeInterval
    
    /// Interval for automatic ping messages in seconds (0 to disable)
    public let pingInterval: TimeInterval
    
    /// Custom headers to include in the WebSocket handshake
    public let headers: [String: String]
    
    public init(
        maxFrameSize: Int = 1024 * 1024, // 1MB default
        enableCompression: Bool = false,
        connectionTimeout: TimeInterval = 30,
        pingInterval: TimeInterval = 30,
        headers: [String: String] = [:]
    ) {
        self.maxFrameSize = maxFrameSize
        self.enableCompression = enableCompression
        self.connectionTimeout = connectionTimeout
        self.pingInterval = pingInterval
        self.headers = headers
    }
}

// MARK: - Default WebSocketClientProtocolProvider Extension

public extension WebSocketClientProtocolProvider {
    /// Default implementation without configuration
    func createClient() -> any WebSocketClientProtocol {
        createClient(configuration: WebSocketConfiguration())
    }
}

// MARK: - WebSocket Errors

public enum WebSocketError: LocalizedError {
    case notConnected
    case connectionFailed(String)
    case sendFailed(String)
    case receiveFailed(String)
    case invalidURL
    case connectionClosed
    case timeout
    
    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "WebSocket is not connected"
        case .connectionFailed(let reason):
            return "WebSocket connection failed: \(reason)"
        case .sendFailed(let reason):
            return "Failed to send message: \(reason)"
        case .receiveFailed(let reason):
            return "Failed to receive message: \(reason)"
        case .invalidURL:
            return "Invalid WebSocket URL"
        case .connectionClosed:
            return "WebSocket connection was closed"
        case .timeout:
            return "WebSocket operation timed out"
        }
    }
}