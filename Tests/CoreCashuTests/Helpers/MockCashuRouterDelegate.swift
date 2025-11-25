import Foundation
@testable import CoreCashu

/// Mock network delegate for testing concurrent operations
/// This provides simulated network responses without requiring actual network calls
final class MockCashuRouterDelegate: @unchecked Sendable {
    var shouldFail = false
    var delay: TimeInterval = 0

    /// Simulate network delay
    func simulateDelay() async {
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    /// Simulate a mint operation
    func mockMint(amount: Int) async throws -> [BlindSignature] {
        await simulateDelay()

        if shouldFail {
            throw CashuError.networkError("Mock mint failed")
        }

        // Return mock blinded signatures
        return (0..<amount).map { i in
            BlindSignature(
                amount: 1,
                id: "mock-keyset-id",
                C_: String(format: "%064x", i)
            )
        }
    }

    /// Simulate a melt operation
    func mockMelt(amount: Int) async throws -> PostMeltResponse {
        await simulateDelay()

        if shouldFail {
            throw CashuError.networkError("Mock melt failed")
        }

        // Return mock melt response
        return PostMeltResponse(
            state: .paid,
            change: []
        )
    }

    /// Simulate a swap operation
    func mockSwap(proofs: [Proof]) async throws -> PostSwapResponse {
        await simulateDelay()

        if shouldFail {
            throw CashuError.networkError("Mock swap failed")
        }

        // Return mock swap response with new signatures
        let signatures = proofs.map { proof in
            BlindSignature(
                amount: proof.amount,
                id: proof.id,
                C_: "mock-signature-\(UUID().uuidString)"
            )
        }

        return PostSwapResponse(
            signatures: signatures
        )
    }
}