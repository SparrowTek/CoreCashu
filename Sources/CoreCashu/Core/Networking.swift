//
//  Networking.swift
//  CashuKit
//
//  Created by Thomas Rademaker on 6/27/25.
//

import Foundation

extension JSONDecoder {
    static var cashuDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let timestampInSeconds = try container.decode(Int.self)
            return Date(timeIntervalSince1970: TimeInterval(timestampInSeconds))
        }
        
        return decoder
    }
}

extension JSONEncoder {
    static var cashuEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        
        return encoder
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

    func shouldRetry(error: any Error, attempts: Int) async throws -> Bool {
        guard attempts < policy.retryPolicy.maxAttempts else { return false }

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
        let path = request.url?.path ?? ""
        if await !rateLimiter.shouldAllowRequest(for: path) {
            try? await rateLimiter.waitForAvailability(for: path)
        }
        await rateLimiter.recordRequest(for: path)

        applyIdempotencyKeyIfNeeded(&request)

        if let url = request.url {
            let key = url.host.map { $0 + url.path } ?? url.absoluteString
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
