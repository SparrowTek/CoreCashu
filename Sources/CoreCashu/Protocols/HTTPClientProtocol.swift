@preconcurrency import Foundation

/// Platform-neutral HTTP client abstraction.
///
/// Prefer using this protocol in Core code instead of referencing
/// concrete networking types. Concrete implementations can adapt
/// `URLSession` (Apple/FoundationNetworking) or other stacks.
public protocol HTTPClientProtocol: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPClientProtocol {}

