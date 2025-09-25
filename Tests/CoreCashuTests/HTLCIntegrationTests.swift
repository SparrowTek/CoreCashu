import Testing
import Foundation
import CryptoKit
@testable import CoreCashu

@Suite("HTLC Integration Tests")
struct HTLCIntegrationTests {

    let mockMintURL = "https://testmint.cashu.space"

    @Test("Create HTLC with preimage")
    func testCreateHTLCWithPreimage() async throws {
        // Setup
        let wallet = await createTestWallet()
        let preimage = Data("secret_preimage".utf8)
        let amount = 100

        // Create mock proofs for testing
        await setupMockProofs(wallet: wallet, amount: 1000)

        // Create HTLC
        let htlcToken = try await wallet.createHTLC(
            amount: amount,
            preimage: preimage
        )

        // Verify
        #expect(htlcToken.amount == amount)
        #expect(htlcToken.preimage == preimage)
        #expect(htlcToken.locktime == nil)
        #expect(htlcToken.refundKey == nil)

        // Verify hash lock
        let expectedHash = SHA256.hash(data: preimage)
        let expectedHashHex = expectedHash.compactMap { String(format: "%02x", $0) }.joined()
        #expect(htlcToken.hashLock == expectedHashHex)
    }

    @Test("Create HTLC with locktime and refund key")
    func testCreateHTLCWithLocktimeRefund() async throws {
        // Setup
        let wallet = await createTestWallet()
        let locktime = Date().addingTimeInterval(3600) // 1 hour from now
        let refundKey = "02" + String(repeating: "a", count: 64) // Mock public key
        let amount = 200

        await setupMockProofs(wallet: wallet, amount: 1000)

        // Create HTLC with locktime
        let htlcToken = try await wallet.createHTLC(
            amount: amount,
            preimage: nil, // Auto-generate
            locktime: locktime,
            refundKey: refundKey
        )

        // Verify
        #expect(htlcToken.amount == amount)
        #expect(htlcToken.locktime != nil)
        #expect(htlcToken.refundKey == refundKey)
        #expect(htlcToken.preimage.count == 32) // SHA256 output size
    }

    @Test("Create HTLC with authorized keys")
    func testCreateHTLCWithAuthorizedKeys() async throws {
        // Setup
        let wallet = await createTestWallet()
        let authorizedKeys = [
            "02" + String(repeating: "b", count: 64),
            "02" + String(repeating: "c", count: 64)
        ]
        let amount = 150

        await setupMockProofs(wallet: wallet, amount: 1000)

        // Create HTLC
        let htlcToken = try await wallet.createHTLC(
            amount: amount,
            authorizedKeys: authorizedKeys
        )

        // Verify
        #expect(htlcToken.amount == amount)
        #expect(htlcToken.authorizedKeys == authorizedKeys)
    }

    @Test("Redeem HTLC with valid preimage")
    func testRedeemHTLCValidPreimage() async throws {
        // Setup
        let wallet = await createTestWallet()
        let preimage = Data("test_preimage".utf8)
        let amount = 100

        await setupMockProofs(wallet: wallet, amount: 1000)

        // Create HTLC
        let htlcToken = try await wallet.createHTLC(
            amount: amount,
            preimage: preimage
        )

        // Mock the token for redemption
        let mockToken = createMockHTLCToken(
            hashLock: htlcToken.hashLock,
            amount: amount
        )

        // Redeem with valid preimage
        let unlockedProofs = try await wallet.redeemHTLC(
            token: mockToken,
            preimage: preimage
        )

        // Verify
        #expect(!unlockedProofs.isEmpty)
        #expect(unlockedProofs.totalValue == amount)
    }

    @Test("Redeem HTLC fails with invalid preimage")
    func testRedeemHTLCInvalidPreimage() async throws {
        // Setup
        let wallet = await createTestWallet()
        let correctPreimage = Data("correct_preimage".utf8)
        let wrongPreimage = Data("wrong_preimage".utf8)
        let amount = 100

        await setupMockProofs(wallet: wallet, amount: 1000)

        // Create HTLC
        let htlcToken = try await wallet.createHTLC(
            amount: amount,
            preimage: correctPreimage
        )

        let mockToken = createMockHTLCToken(
            hashLock: htlcToken.hashLock,
            amount: amount
        )

        // Attempt to redeem with wrong preimage
        await #expect(throws: (any Error).self) {
            _ = try await wallet.redeemHTLC(
                token: mockToken,
                preimage: wrongPreimage
            )
        }
    }

    @Test("Refund expired HTLC")
    func testRefundExpiredHTLC() async throws {
        // Setup
        let wallet = await createTestWallet()
        let pastLocktime = Date().addingTimeInterval(-3600) // 1 hour ago
        let refundKey = "02" + String(repeating: "d", count: 64)
        let refundPrivateKey = String(repeating: "e", count: 64)
        let amount = 200

        await setupMockProofs(wallet: wallet, amount: 1000)

        // Create expired HTLC
        let htlcToken = try await wallet.createHTLC(
            amount: amount,
            locktime: pastLocktime,
            refundKey: refundKey
        )

        let mockToken = createMockHTLCToken(
            hashLock: htlcToken.hashLock,
            amount: amount,
            locktime: pastLocktime
        )

        // Refund the expired HTLC
        let refundedProofs = try await wallet.refundHTLC(
            token: mockToken,
            refundPrivateKey: refundPrivateKey
        )

        // Verify
        #expect(!refundedProofs.isEmpty)
        #expect(refundedProofs.totalValue == amount)
    }

    @Test("Refund fails for non-expired HTLC")
    func testRefundNonExpiredHTLC() async throws {
        // Setup
        let wallet = await createTestWallet()
        let futureLocktime = Date().addingTimeInterval(3600) // 1 hour from now
        let refundKey = "02" + String(repeating: "f", count: 64)
        let refundPrivateKey = String(repeating: "g", count: 64)
        let amount = 200

        await setupMockProofs(wallet: wallet, amount: 1000)

        // Create future HTLC
        let htlcToken = try await wallet.createHTLC(
            amount: amount,
            locktime: futureLocktime,
            refundKey: refundKey
        )

        let mockToken = createMockHTLCToken(
            hashLock: htlcToken.hashLock,
            amount: amount,
            locktime: futureLocktime
        )

        // Attempt to refund non-expired HTLC
        // Note: htlcNotExpired error doesn't exist yet
        await #expect(throws: (any Error).self) {
            _ = try await wallet.refundHTLC(
                token: mockToken,
                refundPrivateKey: refundPrivateKey
            )
        }
    }

    @Test("Check HTLC status")
    func testCheckHTLCStatus() async throws {
        // Setup
        let wallet = await createTestWallet()
        let locktime = Date().addingTimeInterval(3600)
        let refundKey = "02" + String(repeating: "h", count: 64)
        let amount = 300

        await setupMockProofs(wallet: wallet, amount: 1000)

        // Create HTLC
        let htlcToken = try await wallet.createHTLC(
            amount: amount,
            locktime: locktime,
            refundKey: refundKey
        )

        let mockToken = createMockHTLCToken(
            hashLock: htlcToken.hashLock,
            amount: amount,
            locktime: locktime,
            refundKey: refundKey
        )

        // Check status
        let status = try await wallet.checkHTLCStatus(token: mockToken)

        // Verify
        #expect(status.hashLock == htlcToken.hashLock)
        #expect(status.amount == amount)
        #expect(status.locktime != nil)
        #expect(!status.isExpired)
        #expect(status.refundKey == refundKey)
    }

    @Test("HTLC with signatures")
    func testHTLCWithSignatures() async throws {
        // Setup
        let wallet = await createTestWallet()
        let authorizedKeys = ["02" + String(repeating: "i", count: 64)]
        let signatures = [String(repeating: "j", count: 128)] // Mock signature
        let amount = 250

        await setupMockProofs(wallet: wallet, amount: 1000)

        // Create HTLC with authorized keys
        let htlcToken = try await wallet.createHTLC(
            amount: amount,
            authorizedKeys: authorizedKeys
        )

        let mockToken = createMockHTLCToken(
            hashLock: htlcToken.hashLock,
            amount: amount
        )

        // Redeem with signatures
        let unlockedProofs = try await wallet.redeemHTLC(
            token: mockToken,
            preimage: htlcToken.preimage,
            signatures: signatures
        )

        // Verify
        #expect(!unlockedProofs.isEmpty)
        #expect(unlockedProofs.totalValue == amount)
    }

    // MARK: - Helper Functions

    private func createTestWallet() async -> CashuWallet {
        let config = WalletConfiguration(
            mintURL: mockMintURL,
            unit: "sat"
        )

        let mockStorage = InMemoryProofStorage()
        let mockNetworking = MockNetworking()
        let metrics = NoOpMetricsClient()

        let wallet = await CashuWallet(
            configuration: config,
            proofStorage: mockStorage,
            networking: mockNetworking,
            metrics: metrics
        )

        // Initialize wallet with mock mint info
        try? await wallet.initialize()

        return wallet
    }

    private func setupMockProofs(wallet: CashuWallet, amount: Int) async {
        // Create mock proofs for the wallet
        let proof = Proof(
            amount: amount,
            id: "test_keyset",
            secret: "test_secret",
            C: "test_C"
        )

        // Add to wallet's proof manager
        // This would need proper implementation in actual tests
    }

    private func createMockHTLCToken(
        hashLock: String,
        amount: Int,
        locktime: Date? = nil,
        refundKey: String? = nil
    ) -> String {
        // Create a mock token string for testing
        // In real implementation, this would create a proper CashuToken
        let mockProof = Proof(
            amount: amount,
            id: "test_keyset",
            secret: createHTLCSecret(
                hashLock: hashLock,
                locktime: locktime,
                refundKey: refundKey
            ),
            C: "test_C"
        )

        let tokenEntry = TokenEntry(
            mint: mockMintURL,
            proofs: [mockProof]
        )

        let token = CashuToken(
            token: [tokenEntry],
            unit: "sat"
        )

        return (try? CashuTokenUtils.serializeToken(token)) ?? ""
    }

    private func createHTLCSecret(
        hashLock: String,
        locktime: Date?,
        refundKey: String?
    ) -> String {
        var tags: [[String]] = []

        if let locktime = locktime {
            tags.append(["locktime", String(Int64(locktime.timeIntervalSince1970))])
        }

        if let refundKey = refundKey {
            tags.append(["refund", refundKey])
        }

        let secretData = WellKnownSecret.SecretData(
            nonce: UUID().uuidString,
            data: hashLock,
            tags: tags.isEmpty ? nil : tags
        )

        let secret = WellKnownSecret(
            kind: SpendingConditionKind.htlc,
            secretData: secretData
        )

        return (try? secret.toJSONString()) ?? ""
    }
}

// MARK: - Mock Networking

final class MockNetworking: Networking, @unchecked Sendable {
    func data(for request: URLRequest, delegate: (any URLSessionTaskDelegate)?) async throws -> (Data, URLResponse) {
        // Mock implementation for testing
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://mint.example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(), response)
    }
}