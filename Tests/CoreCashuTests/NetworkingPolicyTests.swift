import Testing
@testable import CoreCashu
import Foundation

@Suite("Networking policy", .serialized)
struct NetworkingPolicyTests {

    @Test("Retry policy waits for retryable status code")
    func retryPolicyHandlesStatusCodes() async throws {
        let recorder = SleepRecorder()
        let sleeper = TestSleeper(recorder: recorder)
        let policy = NetworkingPolicy(retryPolicy: HTTPRetryPolicy(maxAttempts: 3, baseDelay: 0.01, jitter: 0))
        let delegate = await CashuRouterDelegate(
            policy: policy,
            rateLimiter: MockRateLimiter(alwaysAllow: true),
            sleeper: sleeper
        )

        let retry = try await delegate.shouldRetry(
            error: NetworkError.statusCode(.internalServerError, data: Data()),
            attempts: 1
        )

        #expect(retry)
        let delays = await recorder.allDelays()
        #expect(delays.count == 1)
        #expect((delays.first ?? -1) >= 0)
    }

    @Test("Retry policy stops for non-retryable errors")
    func retryPolicyStopsForNonRetryable() async throws {
        let delegate = await CashuRouterDelegate(
            policy: .immediateRetrying,
            rateLimiter: MockRateLimiter(alwaysAllow: true),
            sleeper: TestSleeper(recorder: SleepRecorder())
        )

        let retry = try await delegate.shouldRetry(
            error: NetworkError.statusCode(.badRequest, data: Data()),
            attempts: 1
        )

        #expect(retry == false)
    }

    @Test("Idempotency key applied to mutating requests")
    func idempotencyKeyApplied() async {
        let delegate = await CashuRouterDelegate(
            policy: .immediateRetrying,
            rateLimiter: MockRateLimiter(alwaysAllow: true),
            idempotencyKeyProvider: { _ in "test-key" },
            sleeper: TestSleeper(recorder: SleepRecorder())
        )

        var request = URLRequest(url: URL(string: "https://mint.example.com/mint")!)
        request.httpMethod = HTTPMethod.post.rawValue
        await delegate.intercept(&request)

        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "test-key")

        // Existing key is preserved
        request.setValue("existing", forHTTPHeaderField: "Idempotency-Key")
        await delegate.intercept(&request)
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "existing")
    }

    @Test("Rate limiter waits when requests exceed allowance")
    func rateLimiterWaitsWhenLimited() async {
        let limiter = MockRateLimiter(alwaysAllow: false)
        let delegate = await CashuRouterDelegate(
            policy: .immediateRetrying,
            rateLimiter: limiter,
            idempotencyKeyProvider: { _ in "key" },
            sleeper: TestSleeper(recorder: SleepRecorder())
        )

        var request = URLRequest(url: URL(string: "https://mint.example.com/mint")!)
        request.httpMethod = HTTPMethod.post.rawValue
        await delegate.intercept(&request)

        let stats = await limiter.snapshot
        #expect(stats.shouldAllowCalls == 1)
        #expect(stats.waitCalls == 1)
        #expect(stats.recordCalls == 1)
    }

    @Test("Network router honours retry policy")
    func networkRouterRetriesAndSucceeds() async throws {
        let recorder = SleepRecorder()
        let delegate = await CashuRouterDelegate(
            policy: NetworkingPolicy(
                retryPolicy: HTTPRetryPolicy(maxAttempts: 3, baseDelay: 0, jitter: 0),
                rateLimit: .default,
                circuitBreaker: .default
            ),
            rateLimiter: MockRateLimiter(alwaysAllow: true),
            sleeper: TestSleeper(recorder: recorder)
        )

        let networking = FlakyNetworking(failuresBeforeSuccess: 2)
        let router = await NetworkRouter<NetworkingPolicyEndpoint>(networking: networking)
        await router.setDelegate(delegate)

        let endpoint = NetworkingPolicyEndpoint(
            baseURL: URL(string: "https://example.com")!,
            path: "/mint",
            httpMethod: .get,
            task: .request
        )

        let response: NetworkingPolicyDummyResponse = try await router.execute(endpoint)
        #expect(response.flag == true)
        #expect(await networking.getAttempts() == 3)
    }
}

// MARK: - Test Helpers

private struct NetworkingPolicyDummyResponse: CashuDecodable {
    let flag: Bool
}

private struct NetworkingPolicyEndpoint: EndpointType {
    var baseURL: URL
    var path: String
    var httpMethod: HTTPMethod
    var task: HTTPTask
    var headers: HTTPHeaders? { get async { nil } }
}

private struct TestSleeper: SleepProviding {
    let recorder: SleepRecorder
    func sleep(seconds: TimeInterval) async throws {
        await recorder.record(seconds)
    }
}

private actor SleepRecorder {
    private var delays: [TimeInterval] = []

    func record(_ seconds: TimeInterval) {
        delays.append(seconds)
    }

    func allDelays() -> [TimeInterval] {
        delays
    }
}

private actor MockRateLimiter: EndpointRateLimiting {
    private var allowSequence: [Bool]
    private(set) var shouldAllowCalls = 0
    private(set) var waitCalls = 0
    private(set) var recordCalls = 0

    init(alwaysAllow: Bool) {
        self.allowSequence = alwaysAllow ? [] : [false, true]
    }

    func shouldAllowRequest(for endpoint: String) async -> Bool {
        shouldAllowCalls += 1
        if allowSequence.isEmpty { return true }
        return allowSequence.removeFirst()
    }

    func waitForAvailability(for endpoint: String) async throws {
        waitCalls += 1
    }

    func recordRequest(for endpoint: String) async {
        recordCalls += 1
    }

    var snapshot: (shouldAllowCalls: Int, waitCalls: Int, recordCalls: Int) {
        (shouldAllowCalls, waitCalls, recordCalls)
    }
}

private actor FlakyNetworking: Networking {
    var failuresBeforeSuccess: Int
    private var attempts: Int = 0

    init(failuresBeforeSuccess: Int) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func data(for request: URLRequest, delegate: (any URLSessionTaskDelegate)?) async throws -> (Data, URLResponse) {
        attempts += 1
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            throw URLError(.timedOut)
    }
        let data = Data("{\"flag\":true}".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }

    func getAttempts() -> Int {
        attempts
    }
}
