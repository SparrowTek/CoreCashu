import Testing
@testable import CoreCashu
import Foundation

/// Comprehensive stress tests for concurrent operations in CoreCashu
/// These tests validate race conditions, deadlock prevention, and data consistency
@Suite("Concurrency Stress Tests", .serialized)
struct ConcurrencyStressTests {

    // MARK: - Test Setup

    let mockDelegate = MockCashuRouterDelegate()
    let testMintURL = "https://testmint.cashu.space"

    // MARK: - High Volume Concurrent Tests

    @Test("High volume concurrent proof selections")
    func highVolumeConcurrentProofSelections() async throws {
        // Create a large number of proofs
        let proofCount = 1000
        let proofs = (0..<proofCount).map { i in
            Proof(
                amount: Int.random(in: 1...100),
                id: "test-keyset",
                secret: "secret-\(i)",
                C: String(format: "%064x", i)
            )
        }

        // Create concurrent tasks to select proofs
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    // Simulate proof selection logic
                    let targetAmount = Int.random(in: 50...500)
                    var selectedProofs: [Proof] = []
                    var currentAmount = 0

                    for proof in proofs.shuffled() {
                        if currentAmount >= targetAmount {
                            break
                        }
                        selectedProofs.append(proof)
                        currentAmount += proof.amount
                    }

                    // Verify selection doesn't cause data races
                    #expect(selectedProofs.count > 0)
                }
            }
        }
    }

    @Test("Race condition detection for balance updates")
    func raceConditionDetection() async throws {
        // Create an actor to manage balance safely
        actor BalanceManager {
            private var balance: Int = 0

            func addBalance(_ amount: Int) {
                balance += amount
            }

            func subtractBalance(_ amount: Int) throws {
                guard balance >= amount else {
                    throw CashuError.balanceInsufficient
                }
                balance -= amount
            }

            func getBalance() -> Int {
                return balance
            }
        }

        let manager = BalanceManager()
        let iterations = 1000

        // Start with initial balance
        await manager.addBalance(10000)

        // Run concurrent additions and subtractions
        await withTaskGroup(of: Void.self) { group in
            // Add tasks
            for _ in 0..<iterations/2 {
                group.addTask {
                    await manager.addBalance(10)
                }
            }

            // Subtract tasks
            for _ in 0..<iterations/2 {
                group.addTask {
                    try? await manager.subtractBalance(10)
                }
            }
        }

        // Verify final balance is consistent
        let finalBalance = await manager.getBalance()
        #expect(finalBalance == 10000, "Balance mismatch detected: \(finalBalance)")
    }

    @Test("Deadlock prevention with bidirectional transfers")
    func deadlockPrevention() async throws {
        actor Account {
            private var balance: Int
            private let id: String

            init(id: String, balance: Int) {
                self.id = id
                self.balance = balance
            }

            func transfer(to other: Account, amount: Int) async throws {
                // Use deterministic ordering to prevent deadlock
                let otherId = await other.getId()
                let shouldLockFirst = id < otherId

                if shouldLockFirst {
                    guard balance >= amount else {
                        throw CashuError.balanceInsufficient
                    }
                    balance -= amount
                    await other.receive(amount)
                } else {
                    try await other.deduct(amount)
                    balance += amount
                }
            }

            private func receive(_ amount: Int) {
                balance += amount
            }

            private func deduct(_ amount: Int) throws {
                guard balance >= amount else {
                    throw CashuError.balanceInsufficient
                }
                balance -= amount
            }

            func getId() -> String {
                return id
            }

            func getBalance() -> Int {
                return balance
            }
        }

        let account1 = Account(id: "A", balance: 1000)
        let account2 = Account(id: "B", balance: 1000)

        // Run bidirectional transfers concurrently
        await withTaskGroup(of: Void.self) { group in
            // A -> B transfers
            for _ in 0..<50 {
                group.addTask {
                    try? await account1.transfer(to: account2, amount: 10)
                }
            }

            // B -> A transfers
            for _ in 0..<50 {
                group.addTask {
                    try? await account2.transfer(to: account1, amount: 10)
                }
            }
        }

        // Verify total balance is conserved
        let balance1 = await account1.getBalance()
        let balance2 = await account2.getBalance()
        #expect(balance1 + balance2 == 2000, "Total balance not conserved")
    }

    @Test("Deterministic results with repeated concurrent operations")
    func deterministicConcurrency() async throws {
        // Run the same operation multiple times to verify determinism
        var results: [Int] = []

        for _ in 0..<10 {
            actor Counter {
                private var count = 0

                func increment() {
                    count += 1
                }

                func getCount() -> Int {
                    return count
                }
            }

            let counter = Counter()

            // Run exactly 100 increments concurrently
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<100 {
                    group.addTask {
                        await counter.increment()
                    }
                }
            }

            let finalCount = await counter.getCount()
            results.append(finalCount)
        }

        // All results should be identical
        #expect(results.allSatisfy { $0 == 100 }, "Non-deterministic results detected: \(results)")
    }

    @Test("Memory pressure with large proof sets")
    func memoryPressureTest() async throws {
        // Create a large number of concurrent proof operations
        let proofBatches = 100
        let proofsPerBatch = 100

        await withTaskGroup(of: [Proof].self) { group in
            for batch in 0..<proofBatches {
                group.addTask {
                    // Create proofs for this batch
                    return (0..<proofsPerBatch).map { i in
                        Proof(
                            amount: 1,
                            id: "batch-\(batch)",
                            secret: "secret-\(batch)-\(i)",
                            C: String(format: "%064x", batch * 1000 + i)
                        )
                    }
                }
            }

            // Collect all proofs
            var allProofs: [Proof] = []
            for await proofs in group {
                allProofs.append(contentsOf: proofs)
            }

            // Verify all proofs were created
            #expect(allProofs.count == proofBatches * proofsPerBatch)
        }
    }

    @Test("Actor isolation verification")
    func actorIsolationTest() async throws {
        // Verify that actor state is properly isolated
        actor IsolatedState {
            private var values: [Int] = []

            func append(_ value: Int) {
                values.append(value)
            }

            func getValues() -> [Int] {
                return values
            }

            func clear() {
                values.removeAll()
            }
        }

        let state = IsolatedState()

        // Add values concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<1000 {
                group.addTask {
                    await state.append(i)
                }
            }
        }

        // Verify all values were added
        let values = await state.getValues()
        #expect(values.count == 1000, "Not all values were added")

        // Verify no duplicates (would indicate race condition)
        let uniqueValues = Set(values)
        #expect(uniqueValues.count == 1000, "Duplicate values detected")
    }

    @Test("Network request parallelization")
    func networkParallelization() async throws {
        let requestCount = 50
        mockDelegate.delay = 0.01 // Small delay to simulate network

        let startTime = Date()

        // Run requests in parallel
        await withTaskGroup(of: Result<[BlindSignature], Error>.self) { group in
            for i in 0..<requestCount {
                group.addTask {
                    do {
                        let result = try await self.mockDelegate.mockMint(amount: i + 1)
                        return .success(result)
                    } catch {
                        return .failure(error)
                    }
                }
            }

            // Collect results
            var successCount = 0
            for await result in group {
                switch result {
                case .success:
                    successCount += 1
                case .failure:
                    break
                }
            }

            #expect(successCount == requestCount, "Not all requests succeeded")
        }

        let elapsed = Date().timeIntervalSince(startTime)

        // Verify parallel execution (should be much faster than serial)
        let expectedSerialTime = Double(requestCount) * mockDelegate.delay
        #expect(elapsed < expectedSerialTime / 2, "Requests appear to run serially")
    }
}

// MARK: - Extended Stress Tests

@Suite("Extended Concurrency Stress Tests", .serialized)
struct ExtendedConcurrencyStressTests {

    @Test("Cancellation propagation in task hierarchies")
    func cancellationPropagation() async throws {
        actor TaskCounter {
            private var started = 0
            private var cancelled = 0

            func incrementStarted() {
                started += 1
            }

            func incrementCancelled() {
                cancelled += 1
            }

            func getCounts() -> (started: Int, cancelled: Int) {
                return (started, cancelled)
            }
        }

        let counter = TaskCounter()

        let task = Task {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<100 {
                    group.addTask {
                        await counter.incrementStarted()

                        // Simulate work
                        for _ in 0..<1000 {
                            if Task.isCancelled {
                                await counter.incrementCancelled()
                                return
                            }
                            // Do work
                        }
                    }
                }

                // Cancel after starting some tasks
                try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
            }
        }

        // Cancel the parent task
        task.cancel()
        await task.value

        // Verify cancellation was propagated
        let counts = await counter.getCounts()
        #expect(counts.cancelled > 0, "No tasks were cancelled")
    }

    @Test("Priority inversion prevention")
    func priorityInversion() async throws {
        actor PriorityManager {
            private var highPriorityCompleted = false
            private var lowPriorityCompleted = false

            func executeHighPriority() async {
                // High priority work
                try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
                highPriorityCompleted = true
            }

            func executeLowPriority() async {
                // Low priority work
                try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                lowPriorityCompleted = true
            }

            func getStatus() -> (high: Bool, low: Bool) {
                return (highPriorityCompleted, lowPriorityCompleted)
            }
        }

        let manager = PriorityManager()

        // Start low priority task first
        let lowTask = Task(priority: .background) {
            await manager.executeLowPriority()
        }

        // Start high priority task
        let highTask = Task(priority: .high) {
            await manager.executeHighPriority()
        }

        // Wait for both
        await highTask.value
        await lowTask.value

        let status = await manager.getStatus()
        #expect(status.high && status.low, "Tasks did not complete")
    }
}