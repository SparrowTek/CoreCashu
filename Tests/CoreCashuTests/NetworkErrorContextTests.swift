import Testing
@testable import CoreCashu
import Foundation

/// Tests for `NetworkErrorContext` and the `CashuError.networkFailure` /
/// `CashuError.wrappedFailure` cases added in Phase 5.4.
@Suite("CashuError — structured network/wrapped failures")
struct NetworkErrorContextTests {

    @Test("networkFailure with 5xx is retryable")
    func test5xxIsRetryable() {
        let err = CashuError.networkFailure(NetworkErrorContext(
            message: "Internal Server Error",
            httpStatus: 500,
            responseBody: nil
        ))
        #expect(err.isRetryable == true)
        #expect(err.category == .network)
    }

    @Test("networkFailure with 429 is retryable")
    func test429IsRetryable() {
        let err = CashuError.networkFailure(NetworkErrorContext(
            message: "Too Many Requests",
            httpStatus: 429
        ))
        #expect(err.isRetryable == true)
    }

    @Test("networkFailure with 4xx (other than 429) is not retryable")
    func test4xxIsNotRetryable() {
        let err = CashuError.networkFailure(NetworkErrorContext(
            message: "Bad Request",
            httpStatus: 400
        ))
        #expect(err.isRetryable == false)
    }

    @Test("networkFailure with no status (transport-level) is retryable")
    func testNoStatusIsRetryable() {
        // No HTTP status means the request never made it to a response — DNS, TLS, timeout,
        // socket close. Always treat as transient.
        let err = CashuError.networkFailure(NetworkErrorContext(
            message: "Connection timed out"
        ))
        #expect(err.isRetryable == true)
    }

    @Test("Response body is capped to defaultResponseBodyCap")
    func testResponseBodyCap() {
        let cap = NetworkErrorContext.defaultResponseBodyCap
        let oversized = String(repeating: "A", count: cap + 100)
        let context = NetworkErrorContext(
            message: "5xx",
            httpStatus: 500,
            responseBody: oversized
        )
        let body = try? #require(context.responseBody)
        #expect(body?.count == cap + "…[truncated]".count)
        #expect(body?.hasSuffix("…[truncated]") == true)
    }

    @Test("Body under the cap is preserved as-is")
    func testShortBodyIsNotTruncated() {
        let body = "the mint sneezed"
        let context = NetworkErrorContext(
            message: "5xx",
            httpStatus: 500,
            responseBody: body
        )
        #expect(context.responseBody == body)
    }

    @Test("wrappedFailure preserves underlying error type")
    func testWrappedFailurePreservesType() {
        struct UnderlyingError: Error, Sendable {
            let detail: String
        }
        let underlying = UnderlyingError(detail: "boom")
        let err = CashuError.wrappedFailure(message: "wrap me", underlying: underlying)

        // Pattern-match: callers can recover the underlying type rather than parsing strings.
        switch err {
        case .wrappedFailure(_, let underlyingError):
            let extracted = underlyingError as? UnderlyingError
            #expect(extracted?.detail == "boom")
        default:
            #expect(Bool(false), "Expected .wrappedFailure case")
        }
    }

    @Test("Error description includes status and capped body")
    func testErrorDescriptionFormatting() {
        let err = CashuError.networkFailure(NetworkErrorContext(
            message: "boom",
            httpStatus: 503,
            responseBody: "service unavailable"
        ))
        let desc = err.errorDescription ?? ""
        #expect(desc.contains("status=503"))
        #expect(desc.contains("service unavailable"))
    }
}
