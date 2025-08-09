@preconcurrency import Foundation


public protocol Networking: Sendable {
    func data(for request: URLRequest, delegate: (any URLSessionTaskDelegate)?) async throws -> (Data, URLResponse)
}

extension URLSession: Networking { }
