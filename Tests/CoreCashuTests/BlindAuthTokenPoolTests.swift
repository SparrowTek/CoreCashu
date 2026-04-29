import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CoreCashu

/// Phase 8.2 follow-up (2026-04-29) — tests for the BAT pool semantics: pre-mint, draw-one,
/// refresh-below-watermark, header attachment.
@Suite("NUT-22 BAT pool")
struct BlindAuthTokenPoolTests {

    private static func fakeProof(secret: String) -> Proof {
        Proof(amount: 1, id: "00pool", secret: secret, C: "0200")
    }

    @Test("Pool draws tokens FIFO and decrements depth")
    func drawsFIFO() async {
        let pool = BlindAuthTokenPool(lowWatermark: 0, target: 4)
        await pool.add([
            Self.fakeProof(secret: "alpha"),
            Self.fakeProof(secret: "beta"),
            Self.fakeProof(secret: "gamma")
        ])
        #expect(await pool.count == 3)

        let first = await pool.next()
        let second = await pool.next()
        let third = await pool.next()

        #expect(first?.secret == "alpha")
        #expect(second?.secret == "beta")
        #expect(third?.secret == "gamma")
        #expect(await pool.count == 0)
    }

    @Test("next() returns nil when the pool is empty")
    func nextReturnsNilWhenEmpty() async {
        let pool = BlindAuthTokenPool(lowWatermark: 0, target: 4)
        let drawn = await pool.next()
        #expect(drawn == nil)
    }

    @Test("Refresh handler fires when depth drops below low watermark")
    func refreshFiresBelowWatermark() async throws {
        let pool = BlindAuthTokenPool(lowWatermark: 2, target: 5)
        let refreshTracker = RefreshTracker()
        await pool.setRefreshHandler { pool in
            await refreshTracker.bump()
            // Refill back to target.
            await pool.add([
                Self.fakeProof(secret: "fresh-a"),
                Self.fakeProof(secret: "fresh-b"),
                Self.fakeProof(secret: "fresh-c")
            ])
        }

        // Seed with three tokens so the very first draw lands above the watermark and the
        // next one trips it.
        await pool.add([
            Self.fakeProof(secret: "seed-a"),
            Self.fakeProof(secret: "seed-b"),
            Self.fakeProof(secret: "seed-c")
        ])

        // Drawing once leaves count == 2 == lowWatermark — not strictly below, no refresh.
        _ = await pool.next()
        #expect(await pool.count == 2)
        // Drawing again leaves count == 1 < 2 — refresh fires.
        _ = await pool.next()

        // Allow refresh task to run.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await refreshTracker.callCount >= 1, "expected refresh handler to fire")
        #expect(await pool.count >= 1, "expected refresh handler to add tokens")
    }

    @Test("drain returns all remaining tokens and empties the pool")
    func drainEmptiesPool() async {
        let pool = BlindAuthTokenPool()
        await pool.add([Self.fakeProof(secret: "x"), Self.fakeProof(secret: "y")])
        let drained = await pool.drain()
        #expect(drained.count == 2)
        #expect(await pool.count == 0)
    }

    @Test("BlindAuthHeader.apply sets the Blind-auth header to the token's secret")
    func headerAttaches() {
        let token = Self.fakeProof(secret: "header-token-secret")
        var request = URLRequest(url: URL(string: "https://mint.example/v1/swap")!)
        BlindAuthHeader.apply(to: &request, token: token)
        #expect(request.value(forHTTPHeaderField: NUT22Endpoints.blindAuthHeader) == "header-token-secret")
    }
}

private actor RefreshTracker {
    private(set) var callCount = 0
    func bump() { callCount += 1 }
}
