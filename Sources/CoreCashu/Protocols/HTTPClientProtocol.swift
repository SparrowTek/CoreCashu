@preconcurrency import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Platform-neutral HTTP client abstraction.
///
/// Prefer using this protocol in Core code instead of referencing
/// concrete networking types. Concrete implementations can adapt
/// `URLSession` (Apple/FoundationNetworking) or other stacks.
public protocol HTTPClientProtocol: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

// `URLSession` is a real Apple type on Apple platforms and a `FoundationNetworking` re-export
// on Linux. The Linux variant is shipped as a `typealias = AnyObject`, so a protocol
// conformance via extension fails to compile (`AnyObject` isn't a nominal type that can be
// extended). On Apple, `URLSession` already exposes `data(for:)` so the conformance is purely
// a marker. Phase 8.13 follow-up.
#if !os(Linux)
extension URLSession: HTTPClientProtocol {}
#endif

