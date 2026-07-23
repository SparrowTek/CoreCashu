//
//  Networking.swift
//  CashuKit
//
//  Created by Thomas Rademaker on 6/27/25.
//

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension JSONDecoder {
    /// Decoder for mint HTTP responses.
    ///
    /// Uses the default key strategy: every Cashu DTO declares explicit `CodingKeys`
    /// for its snake_case JSON fields (e.g. `fee_reserve`, `input_fee_ppk`).
    /// `convertFromSnakeCase` must never be reintroduced here — it rewrites the JSON
    /// keys before explicit `CodingKeys` are matched, which silently nils optional
    /// fields like `PostMeltQuoteResponse.feeReserve` and mangles the keys of
    /// `[String: AnyCodable]` payloads such as `MintInfo.nuts` settings.
    static var cashuDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let timestampInSeconds = try container.decode(Int.self)
            return Date(timeIntervalSince1970: TimeInterval(timestampInSeconds))
        }
        
        return decoder
    }
}

extension JSONEncoder {
    /// Encoder counterpart to ``JSONDecoder/cashuDecoder`` — default key strategy,
    /// snake_case comes from each DTO's explicit `CodingKeys`.
    static var cashuEncoder: JSONEncoder {
        JSONEncoder()
    }
}

/// Shared helpers for keying per-endpoint state (rate limiters, circuit breakers).
enum EndpointKeyNormalizer {
    /// Collapse per-resource URL paths onto their endpoint template so state maps stay
    /// bounded: `/v1/melt/quote/bolt11/TRmjduhIsPxd9YWKZikuRi6g` and every other quote
    /// share one key. Any path segment of 16+ ID-ish characters (quote IDs, keyset IDs)
    /// is replaced with a placeholder; the fixed protocol segments (`mint`, `melt`,
    /// `quote`, `bolt11`, …) are all shorter and pass through untouched.
    static func normalize(path: String) -> String {
        let segments = path.split(separator: "/").map { segment -> Substring in
            if segment.count >= 16, segment.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
                return "{id}"
            }
            return segment
        }
        return "/" + segments.joined(separator: "/")
    }

    /// Circuit-breaker key for a request: host + normalized path, so per-quote URLs
    /// share one breaker per endpoint instead of minting an entry per quote ID.
    static func breakerKey(for request: URLRequest) -> String? {
        guard let url = request.url else { return nil }
        let path = normalize(path: url.path)
        return url.host.map { $0 + path } ?? url.absoluteString
    }

    /// True when the error proves the endpoint is alive and answering (an active 4xx
    /// rejection other than 408/429). Such errors must not open the circuit breaker.
    static func isEndpointHealthySignal(_ error: any Error) -> Bool {
        if case NetworkError.statusCode(let code?, _) = error {
            let raw = code.rawValue
            return (400..<500).contains(raw) && raw != 408 && raw != 429
        }
        return false
    }
}

@CashuActor
class CashuRouterDelegate: NetworkRouterDelegate {
    private let policy: NetworkingPolicy
    private let rateLimiter: any EndpointRateLimiting
    private let idempotencyKeyProvider: @Sendable (URLRequest) -> String
    private let sleeper: any SleepProviding
    private var breakers: [String: EndpointCircuitBreaker] = [:]

    init(
        policy: NetworkingPolicy = .default,
        rateLimiter: (any EndpointRateLimiting)? = nil,
        idempotencyKeyProvider: (@Sendable (URLRequest) -> String)? = nil,
        sleeper: any SleepProviding = TaskSleeper()
    ) {
        self.policy = policy
        self.rateLimiter = rateLimiter ?? EndpointRateLimiter(defaultConfiguration: policy.rateLimit)
        self.idempotencyKeyProvider = idempotencyKeyProvider ?? { _ in UUID().uuidString }
        self.sleeper = sleeper
    }

    var maxRetryAttempts: Int { policy.retryPolicy.maxAttempts }

    func shouldRetry(request: URLRequest, error: any Error, attempts: Int) async throws -> Bool {
        guard attempts < policy.retryPolicy.maxAttempts else { return false }

        // Only idempotent requests are ever re-sent automatically. Cashu's money-moving
        // endpoints (swap/melt/mint) are POST: a timed-out POST may have been processed,
        // and re-sending it double-submits the operation — mints don't implement the
        // Idempotency-Key header, and NUT-19 response caching is optional. Non-GET
        // failures surface to the wallet layer, which resolves them by re-checking
        // quote/proof state instead of re-sending.
        guard request.httpMethod?.uppercased() == HTTPMethod.get.rawValue.uppercased() else {
            return false
        }

        var shouldRetry = false

        if let networkError = error as? NetworkError {
            switch networkError {
            case .statusCode(let statusCode?, _):
                shouldRetry = policy.retryPolicy.retryableStatusCodes.contains(statusCode)
            case .statusCode(nil, _):
                shouldRetry = false
            case .noData, .noStatusCode:
                shouldRetry = true
            default:
                shouldRetry = false
            }
        } else if let urlError = error as? URLError {
            shouldRetry = policy.retryPolicy.retryableURLErrorCodes.contains(urlError.code)
        }

        guard shouldRetry else { return false }

        let backoff = policy.retryPolicy.baseDelay * pow(2.0, Double(max(attempts - 1, 0)))
        let jitterRange = policy.retryPolicy.jitter
        let jitter = jitterRange > 0 ? Double.random(in: -jitterRange...jitterRange) : 0
        let sleepSeconds = max(0, backoff + jitter)
        try await sleeper.sleep(seconds: sleepSeconds)
        return true
    }

    func intercept(_ request: inout URLRequest) async {
        // Normalized path so per-quote URLs share one limiter/breaker per endpoint
        // instead of growing an entry per quote ID for the process lifetime.
        let path = EndpointKeyNormalizer.normalize(path: request.url?.path ?? "")
        if await !rateLimiter.shouldAllowRequest(for: path) {
            do {
                try await rateLimiter.waitForAvailability(for: path)
            } catch {
                // Cancellation while waiting must not fall through to sending the
                // request anyway — propagate by marking the request denied.
                request.addValue("1", forHTTPHeaderField: "X-Cashu-CB-Denied")
                return
            }
        }
        await rateLimiter.recordRequest(for: path)

        applyIdempotencyKeyIfNeeded(&request)

        if let key = EndpointKeyNormalizer.breakerKey(for: request) {
            if breakers[key] == nil { breakers[key] = EndpointCircuitBreaker(configuration: policy.circuitBreaker) }
            if let breaker = breakers[key], await !breaker.allowRequest() {
                request.addValue("1", forHTTPHeaderField: "X-Cashu-CB-Denied")
            } else {
                request.setValue(nil, forHTTPHeaderField: "X-Cashu-CB-Denied")
            }
        }
    }

    // MARK: - Circuit breaker hooks
    func breakerRecordSuccess(forKey key: String) async {
        if breakers[key] == nil { breakers[key] = EndpointCircuitBreaker(configuration: policy.circuitBreaker) }
        await breakers[key]?.recordSuccess()
    }

    func breakerRecordFailure(forKey key: String) async {
        if breakers[key] == nil { breakers[key] = EndpointCircuitBreaker(configuration: policy.circuitBreaker) }
        await breakers[key]?.recordFailure()
    }

    // MARK: - Helpers

    private func applyIdempotencyKeyIfNeeded(_ request: inout URLRequest) {
        guard let methodRaw = request.httpMethod,
              let method = HTTPMethod(rawValue: methodRaw.uppercased()),
              method.requiresIdempotencyKey,
              request.value(forHTTPHeaderField: "Idempotency-Key")?.isEmpty ?? true
        else { return }

        request.setValue(idempotencyKeyProvider(request), forHTTPHeaderField: "Idempotency-Key")
    }
}

private extension HTTPMethod {
    var requiresIdempotencyKey: Bool {
        switch self {
        case .post, .put, .patch, .delete:
            return true
        default:
            return false
        }
    }
}
