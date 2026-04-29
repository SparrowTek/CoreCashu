import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CoreCashu

/// Behavioural audit of Phase 5.5 — verify ``CashuRouterDelegate`` actually opens its
/// per-endpoint circuit breaker after enough failures and short-circuits subsequent requests.
///
/// We don't drive these through `CashuEnvironment.current.routerDelegate` (the production
/// hookup) because that singleton is shared across the test process: the MockMint suite
/// installs a permissive policy at startup, and races between suites would make the breaker
/// state non-deterministic. Instead, we construct a `CashuRouterDelegate` directly with a
/// tight policy and exercise its public hooks the same way `NetworkRouter.execute` would.
///
/// The architectural claim — every NUT-level service feeds requests into a router that
/// honours `CashuEnvironment.current.routerDelegate` — is enforced by code review at the
/// service init sites (every NUT service stores `self.router.delegate = …`). What this suite
/// verifies is that the delegate, when reached, *behaves* like a breaker.
@Suite("CashuRouterDelegate circuit-breaker behaviour")
struct CircuitBreakerIntegrationTests {

    @CashuActor
    private func makeDelegate(failureThreshold: Int = 4) -> CashuRouterDelegate {
        let policy = NetworkingPolicy(
            retryPolicy: HTTPRetryPolicy(maxAttempts: 1, baseDelay: 0, jitter: 0),
            rateLimit: RateLimitConfiguration(maxRequests: 100_000, timeWindow: 60.0, burstCapacity: 100_000),
            circuitBreaker: CircuitBreakerConfiguration(
                failureThreshold: failureThreshold,
                openTimeout: 600.0,
                halfOpenMaxAttempts: 1
            )
        )
        return CashuRouterDelegate(policy: policy)
    }

    /// Drives the delegate through one failed-request cycle the same way `NetworkRouter` does
    /// post-Phase-7.2: a single `breakerRecordFailure` call per failed attempt (the inner
    /// status-code branch now throws, and only the outer catch records).
    @CashuActor
    private func driveFailedRequest(delegate: CashuRouterDelegate, host: String, path: String) async -> Bool {
        let url = URL(string: "https://\(host)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        await delegate.intercept(&request)
        if request.value(forHTTPHeaderField: "X-Cashu-CB-Denied") == "1" {
            return false
        }
        let key = host + path
        await delegate.breakerRecordFailure(forKey: key)
        return true
    }

    @Test("Breaker opens after threshold failures and denies subsequent requests")
    func opensAndDenies() async throws {
        let delegate = await makeDelegate(failureThreshold: 4)
        let host = "broken.mint"
        let path = "/v1/info"

        // Four failed round-trips reach the threshold; the fifth must be denied.
        for _ in 0..<4 {
            let reached = await driveFailedRequest(delegate: delegate, host: host, path: path)
            #expect(reached == true)
        }
        let denied = await driveFailedRequest(delegate: delegate, host: host, path: path)
        #expect(denied == false, "Breaker must short-circuit after the threshold is hit")
    }

    @Test("Breakers are scoped per endpoint key (host + path)")
    func breakersAreScopedPerEndpoint() async throws {
        let delegate = await makeDelegate(failureThreshold: 4)
        let host = "broken.mint"
        let pathA = "/v1/info"
        let pathB = "/v1/keys"

        // Saturate path A.
        for _ in 0..<4 {
            _ = await driveFailedRequest(delegate: delegate, host: host, path: pathA)
        }
        let deniedA = await driveFailedRequest(delegate: delegate, host: host, path: pathA)
        #expect(deniedA == false)

        // Path B's breaker is independent — first request must still go through.
        let firstB = await driveFailedRequest(delegate: delegate, host: host, path: pathB)
        #expect(firstB == true)
    }

    @Test("recordSuccess resets the breaker before threshold")
    func successResetsBreaker() async throws {
        let delegate = await makeDelegate(failureThreshold: 4)
        let host = "flaky.mint"
        let path = "/v1/info"
        let key = host + path

        // Three failed round-trips — one short of the threshold.
        for _ in 0..<3 {
            _ = await driveFailedRequest(delegate: delegate, host: host, path: path)
        }
        // A success here resets the failure counter.
        await delegate.breakerRecordSuccess(forKey: key)

        // After the reset, three more failed round-trips still don't open the breaker.
        for _ in 0..<3 {
            let reached = await driveFailedRequest(delegate: delegate, host: host, path: path)
            #expect(reached == true, "Breaker should still allow requests after a success reset")
        }
    }

    /// Regression for opus47.md §6.H: ``NetworkRouter.execute`` used to record a failure both in
    /// the inner status-code switch's `default:` branch and in the outer `catch` when the error
    /// rethrew, so the breaker opened at half the configured `failureThreshold` for HTTP errors.
    /// After Phase 7.2 the inner branch only throws and the outer catch records once.
    @Test("Router records exactly one failure per failed attempt (regression for §6.H)")
    func routerRecordsOneFailurePerAttempt() async throws {
        struct FailingEndpoint: EndpointType {
            var baseURL: URL { URL(string: "https://example.invalid")! }
            var path: String { "/v1/info" }
            var httpMethod: HTTPMethod { .get }
            var task: HTTPTask { .request }
            var headers: HTTPHeaders? { nil }
        }

        actor FixedStatusNetworking: Networking {
            let statusCode: Int
            let body: Data
            init(statusCode: Int, body: Data = Data("{}".utf8)) {
                self.statusCode = statusCode
                self.body = body
            }
            func data(for request: URLRequest, delegate: (any URLSessionTaskDelegate)?) async throws -> (Data, URLResponse) {
                let response = HTTPURLResponse(
                    url: request.url ?? URL(string: "https://example.invalid")!,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!
                return (body, response)
            }
        }

        // Threshold of 3 means: pre-fix, two failed attempts (4 records) would open. Post-fix,
        // we need three failed attempts before the *next* attempt is denied.
        let delegate = await makeDelegate(failureThreshold: 3)
        let networking = FixedStatusNetworking(statusCode: 503)
        let router = await NetworkRouter<FailingEndpoint>(networking: networking)
        await router.setDelegate(delegate)

        // Three failed attempts reach the network and each records exactly one failure.
        for _ in 0..<3 {
            do {
                let _: EmptyDecodable = try await router.execute(FailingEndpoint())
                Issue.record("Expected the request to throw a 5xx error")
            } catch NetworkError.statusCode {
                // Expected: HTTP 503 surfaces as NetworkError.statusCode
            } catch NetworkError.circuitOpen {
                Issue.record("Breaker opened too early (would have happened pre-fix at 2 failures)")
            }
        }
        // After three records the breaker is open; the next request is short-circuited.
        do {
            let _: EmptyDecodable = try await router.execute(FailingEndpoint())
            Issue.record("Expected the breaker to deny the request after threshold failures")
        } catch NetworkError.circuitOpen {
            // Expected: post-fix, 3 failures = 3 records = breaker open on the 4th attempt
        } catch {
            Issue.record("Expected NetworkError.circuitOpen, got \(error)")
        }
    }
}

/// Empty-body decodable used solely for the regression test above; we never reach the decode
/// path because the mocked transport returns 5xx responses.
private struct EmptyDecodable: CashuDecodable {}
