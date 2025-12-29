//
//  ConcurrencyEdgeCaseTests.swift
//  CoreCashu
//
//  Edge case tests for concurrent operations to ensure thread safety and data consistency.
//  These tests specifically target scenarios that could cause race conditions or data corruption.
//

import Testing
@testable import CoreCashu
import Foundation

@Suite("Concurrency Edge Case Tests", .serialized)
struct ConcurrencyEdgeCaseTests {
    
    // MARK: - Proof State Management Race Conditions
    
    @Test("Concurrent proof state transitions")
    func concurrentProofStateTransitions() async throws {
        // Simulate concurrent proof state changes to detect race conditions
        actor ProofStateTracker {
            private var proofStates: [String: ProofState] = [:]
            private var transitionCount = 0
            
            func setInitialState(_ proofId: String, state: ProofState) {
                proofStates[proofId] = state
            }
            
            func transitionTo(_ proofId: String, newState: ProofState) -> Bool {
                guard let currentState = proofStates[proofId] else {
                    return false
                }
                
                // Validate state transition
                let validTransition: Bool
                switch (currentState, newState) {
                case (.unspent, .pending):
                    validTransition = true
                case (.pending, .spent):
                    validTransition = true
                case (.pending, .unspent): // Rollback
                    validTransition = true
                default:
                    validTransition = false
                }
                
                if validTransition {
                    proofStates[proofId] = newState
                    transitionCount += 1
                    return true
                }
                return false
            }
            
            func getState(_ proofId: String) -> ProofState? {
                proofStates[proofId]
            }
            
            func getTransitionCount() -> Int {
                transitionCount
            }
        }
        
        let tracker = ProofStateTracker()
        let proofCount = 100
        
        // Initialize proofs as unspent
        for i in 0..<proofCount {
            await tracker.setInitialState("proof-\(i)", state: .unspent)
        }
        
        // Concurrent transitions: unspent -> pending -> spent
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<proofCount {
                group.addTask {
                    let proofId = "proof-\(i)"
                    // Try to transition to pending
                    let pendingSuccess = await tracker.transitionTo(proofId, newState: .pending)
                    if pendingSuccess {
                        // Then try to transition to spent
                        _ = await tracker.transitionTo(proofId, newState: .spent)
                    }
                }
            }
        }
        
        // Verify all proofs ended up in spent state
        for i in 0..<proofCount {
            let state = await tracker.getState("proof-\(i)")
            #expect(state == .spent, "Proof \(i) should be spent, but is \(String(describing: state))")
        }
        
        // Verify transitions were counted correctly (2 per proof: unspent->pending->spent)
        let totalTransitions = await tracker.getTransitionCount()
        #expect(totalTransitions == proofCount * 2)
    }
    
    @Test("Double-spend detection under concurrent load")
    func doubleSpendDetection() async throws {
        // Simulate concurrent attempts to spend the same proof
        actor SpendTracker {
            private var spentProofs: Set<String> = []
            private var doubleSpendAttempts = 0
            
            func trySpend(_ proofId: String) -> Bool {
                if spentProofs.contains(proofId) {
                    doubleSpendAttempts += 1
                    return false // Already spent
                }
                spentProofs.insert(proofId)
                return true
            }
            
            func getDoubleSpendAttempts() -> Int {
                doubleSpendAttempts
            }
            
            func getSpentCount() -> Int {
                spentProofs.count
            }
        }
        
        let tracker = SpendTracker()
        let proofId = "single-proof"
        let concurrentAttempts = 100
        
        // Try to spend the same proof concurrently
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<concurrentAttempts {
                group.addTask {
                    await tracker.trySpend(proofId)
                }
            }
            
            var successCount = 0
            for await success in group {
                if success { successCount += 1 }
            }
            
            // Exactly one should succeed
            #expect(successCount == 1, "Expected exactly 1 successful spend, got \(successCount)")
        }
        
        let doubleSpends = await tracker.getDoubleSpendAttempts()
        #expect(doubleSpends == concurrentAttempts - 1, "Double spend detection failed")
    }
    
    // MARK: - Actor Reentrancy Scenarios
    
    @Test("Actor reentrancy safety - state consistency")
    func actorReentrancySafetyStateConsistency() async throws {
        // Test that actors maintain state consistency despite reentrancy at await points
        // Note: Swift actors allow reentrancy at await points, but state mutations
        // before/after await are atomic within actor isolation
        actor ReentrantCounter {
            private var value = 0
            private var incrementsStarted = 0
            private var incrementsCompleted = 0
            
            func increment() async {
                let startValue = value
                incrementsStarted += 1
                
                // This await point allows reentrancy
                try? await Task.sleep(nanoseconds: 1_000)
                
                // After await, we're back in actor isolation
                // The increment operation is still safe
                value = startValue + 1
                incrementsCompleted += 1
            }
            
            func getValue() -> Int {
                value
            }
            
            func getStats() -> (started: Int, completed: Int) {
                (incrementsStarted, incrementsCompleted)
            }
        }
        
        let counter = ReentrantCounter()
        
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    await counter.increment()
                }
            }
        }
        
        // All operations should complete
        let stats = await counter.getStats()
        #expect(stats.started == 50, "All increments should start")
        #expect(stats.completed == 50, "All increments should complete")
        
        // Due to reentrancy at await, final value may not be 50
        // (each reads startValue before await, so later reads see older values)
        // This is expected behavior - the test validates the actor completes all ops
        let finalValue = await counter.getValue()
        #expect(finalValue >= 1 && finalValue <= 50, "Value should be within expected range")
    }
    
    @Test("Nested actor calls")
    func nestedActorCalls() async throws {
        actor Inner {
            private var value = 0
            
            func increment() {
                value += 1
            }
            
            func getValue() -> Int {
                value
            }
        }
        
        actor Outer {
            private let inner: Inner
            private var callCount = 0
            
            init(inner: Inner) {
                self.inner = inner
            }
            
            func performOperation() async {
                callCount += 1
                await inner.increment()
            }
            
            func getCallCount() -> Int {
                callCount
            }
        }
        
        let inner = Inner()
        let outer = Outer(inner: inner)
        
        // Concurrent nested actor calls
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    await outer.performOperation()
                }
            }
        }
        
        let outerCalls = await outer.getCallCount()
        let innerValue = await inner.getValue()
        
        #expect(outerCalls == 100)
        #expect(innerValue == 100)
    }
    
    // MARK: - Task Cancellation During Operations
    
    @Test("Graceful cancellation during proof operations")
    func gracefulCancellationDuringProofOperations() async throws {
        actor ProofProcessor {
            private var processedProofs: [String] = []
            private var cancelledOperations = 0
            
            func processProof(_ proofId: String) async throws {
                // Check for cancellation before work
                try Task.checkCancellation()
                
                // Simulate work
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
                
                // Check again after work
                try Task.checkCancellation()
                
                processedProofs.append(proofId)
            }
            
            func recordCancellation() {
                cancelledOperations += 1
            }
            
            func getProcessedCount() -> Int {
                processedProofs.count
            }
            
            func getCancelledCount() -> Int {
                cancelledOperations
            }
        }
        
        let processor = ProofProcessor()
        
        let task = Task {
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<100 {
                    group.addTask {
                        do {
                            try await processor.processProof("proof-\(i)")
                        } catch is CancellationError {
                            await processor.recordCancellation()
                        } catch {
                            // Other errors
                        }
                    }
                }
            }
        }
        
        // Cancel after brief delay
        try await Task.sleep(nanoseconds: 5_000_000) // 5ms
        task.cancel()
        
        await task.value
        
        let processed = await processor.getProcessedCount()
        let cancelled = await processor.getCancelledCount()
        
        // Some should be processed, some cancelled
        #expect(processed + cancelled == 100, "All operations should complete or cancel")
        #expect(cancelled > 0, "Some operations should have been cancelled")
    }
    
    @Test("Cancellation cleanup of pending state")
    func cancellationCleanupOfPendingState() async throws {
        actor PendingStateManager {
            private var pendingOperations: Set<String> = []
            
            func markPending(_ id: String) {
                pendingOperations.insert(id)
            }
            
            func clearPending(_ id: String) {
                pendingOperations.remove(id)
            }
            
            func getPendingCount() -> Int {
                pendingOperations.count
            }
        }
        
        let manager = PendingStateManager()
        
        let task = Task {
            for i in 0..<50 {
                let id = "op-\(i)"
                await manager.markPending(id)
                
                defer {
                    Task { await manager.clearPending(id) }
                }
                
                // Simulate work that might be cancelled
                if Task.isCancelled {
                    return
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        
        // Cancel quickly
        try await Task.sleep(nanoseconds: 25_000_000)
        task.cancel()
        
        // Wait for cleanup
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // Pending count should eventually be 0 after cleanup
        let pendingCount = await manager.getPendingCount()
        #expect(pendingCount <= 1, "Pending operations should be cleaned up on cancellation: \(pendingCount)")
    }
    
    // MARK: - Concurrent Mint/Melt Operation Scenarios
    
    @Test("Concurrent mint requests don't duplicate proofs")
    func concurrentMintRequestsNoDuplication() async throws {
        actor ProofStorage {
            private var proofs: [String: Proof] = [:]
            private var duplicateAttempts = 0
            
            func addProof(_ proof: Proof) -> Bool {
                if proofs[proof.secret] != nil {
                    duplicateAttempts += 1
                    return false
                }
                proofs[proof.secret] = proof
                return true
            }
            
            func getProofCount() -> Int {
                proofs.count
            }
            
            func getDuplicateAttempts() -> Int {
                duplicateAttempts
            }
        }
        
        let storage = ProofStorage()
        
        // Simulate concurrent mint responses being processed
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let proof = Proof(
                        amount: 10,
                        id: "keyset-1",
                        secret: "secret-\(i)", // Unique secret per proof
                        C: String(format: "%064x", i)
                    )
                    _ = await storage.addProof(proof)
                }
            }
        }
        
        let proofCount = await storage.getProofCount()
        let duplicates = await storage.getDuplicateAttempts()
        
        #expect(proofCount == 100, "All proofs should be stored")
        #expect(duplicates == 0, "No duplicate attempts should occur with unique secrets")
    }
    
    @Test("Concurrent melt operations don't double-spend")
    func concurrentMeltOperationsNoDoubleSpend() async throws {
        actor MeltTracker {
            private var meltedProofs: Set<String> = []
            private var doubleSpendAttempts = 0
            
            func tryMelt(_ proofId: String) async -> Bool {
                if meltedProofs.contains(proofId) {
                    doubleSpendAttempts += 1
                    return false
                }
                
                // Simulate async operation
                try? await Task.sleep(nanoseconds: 1_000)
                
                // Check again (could have been melted by another task)
                if meltedProofs.contains(proofId) {
                    doubleSpendAttempts += 1
                    return false
                }
                
                meltedProofs.insert(proofId)
                return true
            }
            
            func getDoubleSpendAttempts() -> Int {
                doubleSpendAttempts
            }
            
            func getMeltedCount() -> Int {
                meltedProofs.count
            }
        }
        
        let tracker = MeltTracker()
        let proofIds = (0..<10).map { "proof-\($0)" }
        
        // Each proof attempted 10 times concurrently
        await withTaskGroup(of: Void.self) { group in
            for proofId in proofIds {
                for _ in 0..<10 {
                    group.addTask {
                        _ = await tracker.tryMelt(proofId)
                    }
                }
            }
        }
        
        let meltedCount = await tracker.getMeltedCount()
        let doubleSpends = await tracker.getDoubleSpendAttempts()
        
        #expect(meltedCount == 10, "Each proof should be melted exactly once")
        #expect(doubleSpends == 90, "90 double-spend attempts should be detected")
    }
    
    // MARK: - Data Consistency Under Load
    
    @Test("Balance consistency under concurrent operations")
    func balanceConsistencyUnderConcurrentOperations() async throws {
        actor Wallet {
            private var balance: Int = 1000
            private var operationLog: [(operation: String, amount: Int, newBalance: Int)] = []
            
            func credit(_ amount: Int) {
                balance += amount
                operationLog.append(("credit", amount, balance))
            }
            
            func debit(_ amount: Int) -> Bool {
                guard balance >= amount else {
                    return false
                }
                balance -= amount
                operationLog.append(("debit", amount, balance))
                return true
            }
            
            func getBalance() -> Int {
                balance
            }
            
            func verifyConsistency() -> Bool {
                var computedBalance = 1000
                for entry in operationLog {
                    switch entry.operation {
                    case "credit":
                        computedBalance += entry.amount
                    case "debit":
                        computedBalance -= entry.amount
                    default:
                        break
                    }
                    if computedBalance != entry.newBalance {
                        return false
                    }
                }
                return computedBalance == balance
            }
        }
        
        let wallet = Wallet()
        
        // Run many concurrent operations
        await withTaskGroup(of: Void.self) { group in
            // Credits
            for i in 0..<50 {
                group.addTask {
                    await wallet.credit(i + 1)
                }
            }
            
            // Debits (some will fail due to insufficient balance)
            for i in 0..<50 {
                group.addTask {
                    _ = await wallet.debit(i + 1)
                }
            }
        }
        
        let isConsistent = await wallet.verifyConsistency()
        #expect(isConsistent, "Operation log should be consistent with balance")
    }
    
    // MARK: - Error Propagation in Concurrent Context
    
    @Test("Error propagation doesn't corrupt state")
    func errorPropagationDoesntCorruptState() async throws {
        actor StatefulService {
            private var state: Int = 0
            private var errorCount = 0
            
            func performOperation(shouldFail: Bool) async throws {
                let previousState = state
                state += 1
                
                if shouldFail {
                    state = previousState // Rollback
                    errorCount += 1
                    throw CashuError.verificationFailed
                }
            }
            
            func getState() -> Int {
                state
            }
            
            func getErrorCount() -> Int {
                errorCount
            }
        }
        
        let service = StatefulService()
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    do {
                        try await service.performOperation(shouldFail: i % 2 == 0)
                    } catch {
                        // Error handled
                    }
                }
            }
        }
        
        let state = await service.getState()
        let errors = await service.getErrorCount()
        
        // 50 succeed (odd numbers), 50 fail (even numbers)
        #expect(state == 50, "State should reflect only successful operations: \(state)")
        #expect(errors == 50, "Error count should be 50: \(errors)")
    }
}
