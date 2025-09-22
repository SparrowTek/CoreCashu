import Testing
@testable import CoreCashu
import Foundation

@Suite("Wallet Concurrency Tests")
struct WalletConcurrencyTests {
    
    @Test("Concurrent wallet initialization")
    func concurrentWalletInit() async throws {
        // Test creating multiple wallets concurrently
        await withTaskGroup(of: CashuWallet.self) { group in
            for i in 0..<10 {
                group.addTask {
                    await CashuWallet(mintURL: "https://mint\(i).example.com")
                }
            }
            
            var wallets: [CashuWallet] = []
            for await wallet in group {
                wallets.append(wallet)
            }
            
            #expect(wallets.count == 10)
        }
    }
    
    @Test("Concurrent token operations")
    func concurrentTokenOperations() async throws {
        let wallet = await CashuWallet(mintURL: "https://test.mint.com")
        
        // Create multiple tokens
        let tokens = (0..<5).map { i in
            CashuToken(
                token: [TokenEntry(
                    mint: "https://test.mint.com",
                    proofs: [Proof(
                        amount: 10,
                        id: "0000000000000001",
                        secret: "secret-\(i)",
                        C: String(format: "%064x", i)
                    )]
                )],
                unit: "sat"
            )
        }
        
        // Try to receive tokens concurrently
        await withTaskGroup(of: Void.self) { group in
            for token in tokens {
                group.addTask {
                    _ = try? await wallet.receive(token: token)
                }
            }
        }
        
        // Check wallet did not enter an error state during concurrent receives
        let state = await wallet.state
        let isHealthy: Bool
        if case .error = state {
            isHealthy = false
        } else {
            isHealthy = true
        }
        #expect(isHealthy, "Wallet entered error state: \(state)")
    }
    
    @Test("Task cancellation handling")
    func taskCancellationHandling() async throws {
        let wallet = await CashuWallet(mintURL: "https://slow.mint.com")
        
        let task = Task {
            try await wallet.initialize()
        }
        
        // Cancel immediately
        task.cancel()
        
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
    
    @Test("Concurrent secret generation")
    func concurrentSecretGeneration() async throws {
        actor SecretCollector {
            private var secrets: Set<String> = []
            
            func insert(_ secret: String) -> Bool {
                secrets.insert(secret).inserted
            }
            
            var count: Int {
                secrets.count
            }
        }
        
        let collector = SecretCollector()
        
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    try CashuKeyUtils.generateRandomSecret()
                }
            }
            
            for try await secret in group {
                let isNew = await collector.insert(secret)
                #expect(isNew, "Generated duplicate secret: \(secret)")
            }
        }
        
        #expect(await collector.count == 100)
    }
    
    @Test("Sendable conformance")
    func sendableConformance() async throws {
        // Test that key types can be passed between tasks
        let proof = Proof(
            amount: 100,
            id: "0000000000000007",
            secret: "test-secret",
            C: String(repeating: "A", count: 64)
        )
        
        let task = Task {
            return proof
        }
        
        let receivedProof = await task.value
        #expect(receivedProof.amount == 100)
        #expect(receivedProof.secret == "test-secret")
        
        // Test CashuToken is Sendable
        let token = CashuToken(
            token: [TokenEntry(mint: "https://test", proofs: [proof])],
            unit: "sat"
        )
        
        let tokenTask = Task {
            return token
        }
        
        let receivedToken = await tokenTask.value
        #expect(receivedToken.unit == "sat")
    }
}
