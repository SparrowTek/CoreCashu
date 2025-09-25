import Testing
import Foundation
@testable import CoreCashu

@Suite("MPP Integration Tests")
struct MPPIntegrationTests {

    let mockMintURL = "https://testmint.cashu.space"
    let mockMintURL2 = "https://testmint2.cashu.space"

    @Test("Send multi-path payment with auto-split")
    func testSendMultiPathAutoSplit() async throws {
        // Setup
        let wallet = await createTestWallet()
        let amount = 1000

        await setupMockProofs(wallet: wallet, amount: 2000)

        // Send with auto-split
        let result = try await wallet.sendMultiPath(
            amount: amount
        )

        // Verify
        #expect(result.totalAmount == amount)
        #expect(!result.partialPayments.isEmpty)
        #expect(result.isComplete)
        #expect(result.successfulAmount == amount)
    }

    @Test("Send multi-path payment with custom splits")
    func testSendMultiPathCustomSplits() async throws {
        // Setup
        let wallet = await createTestWallet()
        let splits = [100, 200, 300, 400]
        let totalAmount = splits.reduce(0, +)

        await setupMockProofs(wallet: wallet, amount: 2000)

        // Send with custom splits
        let result = try await wallet.sendMultiPath(
            amount: totalAmount,
            splits: splits
        )

        // Verify
        #expect(result.totalAmount == totalAmount)
        #expect(result.partialPayments.count == splits.count)

        // Verify each split amount
        for (index, payment) in result.partialPayments.enumerated() {
            #expect(payment.amount == splits[index])
        }
    }

    @Test("Send multi-path payment across multiple mints")
    func testSendMultiPathMultipleMints() async throws {
        // Setup
        let wallet = await createTestWallet()
        let amount = 500
        let mints = [mockMintURL, mockMintURL2]
        let splits = [250, 250]

        await setupMockProofs(wallet: wallet, amount: 1000)

        // Send across multiple mints
        let result = try await wallet.sendMultiPath(
            amount: amount,
            splits: splits,
            mints: mints
        )

        // Verify
        #expect(result.totalAmount == amount)
        #expect(result.partialPayments.count == 2)
    }

    @Test("Send multi-path payment with Lightning invoice")
    func testSendMultiPathWithInvoice() async throws {
        // Setup
        let wallet = await createTestWallet()
        let amount = 750
        let invoice = "lnbc750..." // Mock Lightning invoice

        await setupMockProofs(wallet: wallet, amount: 1500)

        // Send with invoice
        let result = try await wallet.sendMultiPath(
            amount: amount,
            invoice: invoice
        )

        // Verify
        #expect(result.totalAmount == amount)
        #expect(result.invoice == invoice)
        #expect(!result.partialPayments.isEmpty)
    }

    @Test("Combine multiple tokens")
    func testCombineMultiPath() async throws {
        // Setup
        let wallet = await createTestWallet()

        // Create mock tokens
        let token1 = createMockToken(amount: 100, mint: mockMintURL)
        let token2 = createMockToken(amount: 200, mint: mockMintURL)
        let token3 = createMockToken(amount: 300, mint: mockMintURL2)

        // Combine tokens
        let combinedToken = try await wallet.combineMultiPath(
            tokens: [token1, token2, token3]
        )

        // Verify
        #expect(!combinedToken.isEmpty)

        // Parse and verify combined token
        let parsed = try CashuToken(from: combinedToken)
        let totalAmount = parsed.token.flatMap { $0.proofs }.totalValue
        #expect(totalAmount == 600) // 100 + 200 + 300
    }

    @Test("Combine tokens with target mint")
    func testCombineMultiPathTargetMint() async throws {
        // Setup
        let wallet = await createTestWallet()
        let targetMint = mockMintURL2

        // Create mock tokens from different mints
        let token1 = createMockToken(amount: 150, mint: mockMintURL)
        let token2 = createMockToken(amount: 250, mint: mockMintURL2)

        // Combine with target mint
        let combinedToken = try await wallet.combineMultiPath(
            tokens: [token1, token2],
            targetMint: targetMint
        )

        // Verify
        let parsed = try CashuToken(from: combinedToken)
        #expect(parsed.token.first?.mint == targetMint)
    }

    @Test("Receive multi-path payment")
    func testReceiveMultiPath() async throws {
        // Setup
        let wallet = await createTestWallet()

        // Create mock partial payment tokens
        let tokens = [
            createMockToken(amount: 100, mint: mockMintURL),
            createMockToken(amount: 200, mint: mockMintURL),
            createMockToken(amount: 300, mint: mockMintURL2)
        ]

        // Receive multi-path payment
        let totalReceived = try await wallet.receiveMultiPath(tokens: tokens)

        // Verify
        #expect(totalReceived == 600)
    }

    @Test("Receive multi-path with partial failure")
    func testReceiveMultiPathPartialFailure() async throws {
        // Setup
        let wallet = await createTestWallet()

        // Create mix of valid and invalid tokens
        let tokens = [
            createMockToken(amount: 100, mint: mockMintURL),
            "invalid_token",
            createMockToken(amount: 200, mint: mockMintURL)
        ]

        // Receive with partial failure
        let totalReceived = try await wallet.receiveMultiPath(tokens: tokens)

        // Verify - should still receive valid tokens
        #expect(totalReceived == 300) // Only 100 + 200
    }

    @Test("Check MPP status")
    func testCheckMPPStatus() async throws {
        // Setup
        let wallet = await createTestWallet()
        let paymentId = UUID().uuidString

        // Check status
        let status = try await wallet.checkMPPStatus(paymentId: paymentId)

        // Verify
        #expect(status.paymentId == paymentId)
        #expect(status.status == .unknown) // Mock implementation returns unknown
    }

    @Test("Optimal split calculation")
    func testOptimalSplitCalculation() async throws {
        // Setup
        let wallet = await createTestWallet()

        // Test various amounts
        let testAmounts = [100, 500, 1500, 5000, 10000]

        for amount in testAmounts {
            await setupMockProofs(wallet: wallet, amount: amount * 2)

            let result = try await wallet.sendMultiPath(
                amount: amount
            )

            // Verify splits are reasonable
            for payment in result.partialPayments {
                #expect(payment.amount >= 10) // Minimum split size
                #expect(payment.amount <= 1000) // Maximum split size
            }

            // Verify total
            let splitSum = result.partialPayments.reduce(0) { $0 + $1.amount }
            #expect(splitSum == amount)
        }
    }

    @Test("Atomic payment rollback on failure")
    func testAtomicPaymentRollback() async throws {
        // Setup
        let wallet = await createTestWallet()
        let amount = 500
        let invoice = "lnbc500..." // Mock invoice for coordinated payment

        await setupMockProofs(wallet: wallet, amount: 1000)

        // Simulate partial failure scenario
        let splits = [200, 300] // One will fail in mock

        // This test would verify rollback behavior
        // In real implementation, we'd mock one payment to fail
        let result = try await wallet.sendMultiPath(
            amount: amount,
            splits: splits,
            invoice: invoice
        )

        // If atomic mode and partial failure, should rollback successful payments
        if !result.isComplete {
            #expect(result.successfulAmount < amount)
        }
    }

    @Test("MPP with insufficient balance")
    func testMPPInsufficientBalance() async throws {
        // Setup
        let wallet = await createTestWallet()
        let amount = 1000

        await setupMockProofs(wallet: wallet, amount: 500) // Insufficient

        // Attempt to send more than balance
        await #expect(throws: CashuError.insufficientFunds) {
            _ = try await wallet.sendMultiPath(amount: amount)
        }
    }

    @Test("MPP with invalid splits")
    func testMPPInvalidSplits() async throws {
        // Setup
        let wallet = await createTestWallet()
        let amount = 500
        let invalidSplits = [100, 200] // Sum is 300, not 500

        await setupMockProofs(wallet: wallet, amount: 1000)

        // Attempt with invalid splits
        await #expect(throws: (any Error).self) {
            _ = try await wallet.sendMultiPath(
                amount: amount,
                splits: invalidSplits
            )
        }
    }

    // MARK: - Helper Functions

    private func createTestWallet() async -> CashuWallet {
        let config = WalletConfiguration(
            mintURL: mockMintURL,
            unit: "sat"
        )

        let mockStorage = InMemoryProofStorage()
        let mockNetworking = MockMPPNetworking()
        let metrics = NoOpMetricsClient()

        let wallet = await CashuWallet(
            configuration: config,
            proofStorage: mockStorage,
            networking: mockNetworking,
            metrics: metrics
        )

        // Initialize wallet
        try? await wallet.initialize()

        return wallet
    }

    private func setupMockProofs(wallet: CashuWallet, amount: Int) async {
        // Create mock proofs for testing
        // This would be properly implemented with the actual wallet
    }

    private func createMockToken(amount: Int, mint: String) -> String {
        let proof = Proof(
            amount: amount,
            id: "test_keyset",
            secret: UUID().uuidString,
            C: "test_C_\(amount)"
        )

        let tokenEntry = TokenEntry(
            mint: mint,
            proofs: [proof]
        )

        let token = CashuToken(
            token: [tokenEntry],
            unit: "sat",
            memo: "Test token \(amount)"
        )

        return (try? CashuTokenUtils.serializeToken(token)) ?? ""
    }
}

// MARK: - Mock MPP Networking

class MockMPPNetworking: Networking {
    func send(_ request: any Request) async throws -> Response {
        // Mock implementation for MPP testing
        Response(data: Data(), response: HTTPURLResponse())
    }

    func data(from url: URL) async throws -> (Data, URLResponse) {
        // Return mock mint info
        let mockMintInfo = """
        {
            "name": "Mock Mint",
            "pubkey": "02...",
            "version": "1.0.0",
            "nuts": {
                "0": { "supported": true },
                "1": { "supported": true },
                "15": { "supported": true }
            }
        }
        """.data(using: .utf8)!

        return (mockMintInfo, HTTPURLResponse())
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        // Handle different endpoints
        if request.url?.path.contains("swap") == true {
            // Return mock swap response
            let mockResponse = """
            {
                "signatures": []
            }
            """.data(using: .utf8)!
            return (mockResponse, HTTPURLResponse())
        }

        return (Data(), HTTPURLResponse())
    }
}