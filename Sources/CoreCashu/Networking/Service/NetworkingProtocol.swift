@preconcurrency import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif


public protocol Networking: Sendable {
    func data(for request: URLRequest, delegate: (any URLSessionTaskDelegate)?) async throws -> (Data, URLResponse)
}

extension URLSession: Networking { }
