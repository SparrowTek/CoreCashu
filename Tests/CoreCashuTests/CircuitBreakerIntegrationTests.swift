import Foundation
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

    /// Drives the delegate through one failed-request cycle the same way `NetworkRouter` does:
    /// `intercept` → record failure twice (once for status code, once for the rethrown error).
    @CashuActor
    private func driveFailedRequest(delegate: CashuRouterDelegate, host: String, path: String) async -> Bool {
        let url = URL(string: "https://\(host)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        await delegate.intercept(&request)
        // If the breaker denied the request, mirror the router's logic: don't record success or
        // failure; the call never went out.
        if request.value(forHTTPHeaderField: "X-Cashu-CB-Denied") == "1" {
            return false
        }
        let key = host + path
        // 5xx response path — router records failure for the status code, then again in the
        // outer catch when the error rethrows.
        await delegate.breakerRecordFailure(forKey: key)
        await delegate.breakerRecordFailure(forKey: key)
        return true
    }

    @Test("Breaker opens after threshold failures and denies subsequent requests")
    func opensAndDenies() async throws {
        let delegate = await makeDelegate(failureThreshold: 4)
        let host = "broken.mint"
        let path = "/v1/info"

        // Two failed round-trips × 2 failure records = 4 — equal to the threshold. The breaker
        // is open after the second round-trip; the third must be denied.
        let firstReached = await driveFailedRequest(delegate: delegate, host: host, path: path)
        let secondReached = await driveFailedRequest(delegate: delegate, host: host, path: path)
        let thirdReached = await driveFailedRequest(delegate: delegate, host: host, path: path)

        #expect(firstReached == true)
        #expect(secondReached == true)
        #expect(thirdReached == false, "Breaker must short-circuit the third request")
    }

    @Test("Breakers are scoped per endpoint key (host + path)")
    func breakersAreScopedPerEndpoint() async throws {
        let delegate = await makeDelegate(failureThreshold: 4)
        let host = "broken.mint"
        let pathA = "/v1/info"
        let pathB = "/v1/keys"

        // Saturate path A.
        _ = await driveFailedRequest(delegate: delegate, host: host, path: pathA)
        _ = await driveFailedRequest(delegate: delegate, host: host, path: pathA)
        let thirdA = await driveFailedRequest(delegate: delegate, host: host, path: pathA)
        #expect(thirdA == false)

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

        // One failed round-trip = 2 failure records (still below the threshold).
        _ = await driveFailedRequest(delegate: delegate, host: host, path: path)
        // A success here resets the failure counter.
        await delegate.breakerRecordSuccess(forKey: key)

        // After the reset, two more *failed* round-trips don't open the breaker — that takes
        // four failure records again from the reset point.
        _ = await driveFailedRequest(delegate: delegate, host: host, path: path)
        let third = await driveFailedRequest(delegate: delegate, host: host, path: path)
        #expect(third == true, "Breaker should still allow requests after a success reset")
    }
}
