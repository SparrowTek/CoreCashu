//
//  ProofStorageTests.swift
//  CoreCashu
//
//  Comprehensive tests for ProofStorage and ProofManager
//

import Testing
import Foundation
@testable import CoreCashu

// MARK: - ProofStorage Tests

@Suite("ProofStorage Tests")
struct ProofStorageTests {
    
    // MARK: - Test Helpers
    
    /// Create a test proof with specified properties
    func createTestProof(
        amount: Int = 100,
        id: String = "test_keyset_001",
        secret: String? = nil,
        C: String? = nil
    ) -> Proof {
        let finalSecret = secret ?? UUID().uuidString
        let finalC = C ?? "02" + String(repeating: "ab", count: 32) // Valid hex compressed public key format
        return Proof(
            amount: amount,
            id: id,
            secret: finalSecret,
            C: finalC
        )
    }
    
    // MARK: - InMemoryProofStorage CRUD Tests
    
    @Test("Store single proof")
    func storeSingleProof() async throws {
        let storage = InMemoryProofStorage()
        let proof = createTestProof()
        
        try await storage.store([proof])
        
        let count = try await storage.count()
        #expect(count == 1)
    }
    
    @Test("Store multiple proofs")
    func storeMultipleProofs() async throws {
        let storage = InMemoryProofStorage()
        let proofs = (0..<5).map { createTestProof(amount: ($0 + 1) * 10) }
        
        try await storage.store(proofs)
        
        let count = try await storage.count()
        #expect(count == 5)
    }
    
    @Test("Store duplicate proofs - deduplication")
    func storeDuplicateProofs() async throws {
        let storage = InMemoryProofStorage()
        let proof = createTestProof(secret: "unique_secret", C: "02abcd1234567890abcd1234567890abcd1234567890abcd1234567890abcd1234")
        
        try await storage.store([proof])
        try await storage.store([proof]) // Store same proof again
        
        let count = try await storage.count()
        #expect(count == 1) // Should still be 1 due to deduplication
    }
    
    @Test("Retrieve all proofs")
    func retrieveAllProofs() async throws {
        let storage = InMemoryProofStorage()
        let proofs = (0..<3).map { createTestProof(amount: ($0 + 1) * 50) }
        
        try await storage.store(proofs)
        let retrieved = try await storage.retrieveAll()
        
        #expect(retrieved.count == 3)
        
        let totalValue = retrieved.reduce(0) { $0 + $1.amount }
        #expect(totalValue == 50 + 100 + 150)
    }
    
    @Test("Retrieve proofs by keyset ID")
    func retrieveByKeysetID() async throws {
        let storage = InMemoryProofStorage()
        let keyset1Proofs = (0..<3).map { _ in createTestProof(amount: 10, id: "keyset_1") }
        let keyset2Proofs = (0..<2).map { _ in createTestProof(amount: 20, id: "keyset_2") }
        
        try await storage.store(keyset1Proofs)
        try await storage.store(keyset2Proofs)
        
        let keyset1Retrieved = try await storage.retrieve(keysetID: "keyset_1")
        let keyset2Retrieved = try await storage.retrieve(keysetID: "keyset_2")
        let keyset3Retrieved = try await storage.retrieve(keysetID: "keyset_3")
        
        #expect(keyset1Retrieved.count == 3)
        #expect(keyset2Retrieved.count == 2)
        #expect(keyset3Retrieved.count == 0)
    }
    
    @Test("Remove proofs")
    func removeProofs() async throws {
        let storage = InMemoryProofStorage()
        let proofs = (0..<5).map { createTestProof(amount: ($0 + 1) * 10) }
        
        try await storage.store(proofs)
        #expect(try await storage.count() == 5)
        
        // Remove first 2 proofs
        try await storage.remove(Array(proofs[0..<2]))
        #expect(try await storage.count() == 3)
    }
    
    @Test("Remove non-existent proof - no error")
    func removeNonExistentProof() async throws {
        let storage = InMemoryProofStorage()
        let proof1 = createTestProof(secret: "secret1")
        let proof2 = createTestProof(secret: "secret2")
        
        try await storage.store([proof1])
        
        // Should not throw when removing non-existent proof
        try await storage.remove([proof2])
        #expect(try await storage.count() == 1)
    }
    
    @Test("Clear all proofs")
    func clearAllProofs() async throws {
        let storage = InMemoryProofStorage()
        let proofs = (0..<10).map { createTestProof(amount: $0 + 1) }
        
        try await storage.store(proofs)
        #expect(try await storage.count() == 10)
        
        try await storage.clear()
        #expect(try await storage.count() == 0)
    }
    
    @Test("Contains proof check")
    func containsProof() async throws {
        let storage = InMemoryProofStorage()
        let proof1 = createTestProof(secret: "secret1")
        let proof2 = createTestProof(secret: "secret2")
        
        try await storage.store([proof1])
        
        #expect(try await storage.contains(proof1))
        #expect(try await !storage.contains(proof2))
    }
    
    @Test("Count proofs")
    func countProofs() async throws {
        let storage = InMemoryProofStorage()
        
        #expect(try await storage.count() == 0)
        
        try await storage.store([createTestProof()])
        #expect(try await storage.count() == 1)
        
        try await storage.store((0..<4).map { createTestProof(amount: $0 + 1) })
        #expect(try await storage.count() == 5)
    }
    
    // MARK: - Transactional Lifecycle Tests
    
    @Test("Mark proofs as pending spent")
    func markAsPendingSpent() async throws {
        let storage = InMemoryProofStorage()
        let proofs = (0..<3).map { createTestProof(amount: ($0 + 1) * 10) }
        
        try await storage.store(proofs)
        try await storage.markAsPendingSpent([proofs[0], proofs[1]])
        
        let pending = try await storage.getPendingSpent()
        #expect(pending.count == 2)
    }
    
    @Test("Finalize pending spent proofs")
    func finalizePendingSpent() async throws {
        let storage = InMemoryProofStorage()
        let proofs = (0..<3).map { createTestProof(amount: ($0 + 1) * 10) }
        
        try await storage.store(proofs)
        try await storage.markAsPendingSpent([proofs[0], proofs[1]])
        
        // Finalize one proof
        try await storage.finalizePendingSpent([proofs[0]])
        
        let pending = try await storage.getPendingSpent()
        #expect(pending.count == 1)
    }
    
    @Test("Rollback pending spent proofs")
    func rollbackPendingSpent() async throws {
        let storage = InMemoryProofStorage()
        let proofs = (0..<3).map { createTestProof(amount: ($0 + 1) * 10) }
        
        try await storage.store(proofs)
        try await storage.markAsPendingSpent([proofs[0], proofs[1]])
        
        // Rollback all pending
        try await storage.rollbackPendingSpent([proofs[0], proofs[1]])
        
        let pending = try await storage.getPendingSpent()
        #expect(pending.count == 0)
    }
    
    @Test("Get pending spent proofs")
    func getPendingSpentProofs() async throws {
        let storage = InMemoryProofStorage()
        
        // Initially empty
        let initialPending = try await storage.getPendingSpent()
        #expect(initialPending.isEmpty)
        
        let proofs = (0..<2).map { createTestProof(amount: ($0 + 1) * 100) }
        try await storage.store(proofs)
        try await storage.markAsPendingSpent(proofs)
        
        let pending = try await storage.getPendingSpent()
        #expect(pending.count == 2)
    }
    
    @Test("Complete transactional workflow - success")
    func transactionalWorkflowSuccess() async throws {
        let storage = InMemoryProofStorage()
        let proofs = (0..<5).map { createTestProof(amount: ($0 + 1) * 10) }
        
        try await storage.store(proofs)
        
        // Mark as pending
        try await storage.markAsPendingSpent(proofs)
        #expect(try await storage.getPendingSpent().count == 5)
        
        // Finalize (success case)
        try await storage.finalizePendingSpent(proofs)
        #expect(try await storage.getPendingSpent().count == 0)
        
        // Storage still has proofs (InMemory doesn't auto-remove on finalize)
        #expect(try await storage.count() == 5)
    }
    
    @Test("Complete transactional workflow - failure and rollback")
    func transactionalWorkflowFailure() async throws {
        let storage = InMemoryProofStorage()
        let proofs = (0..<5).map { createTestProof(amount: ($0 + 1) * 10) }
        
        try await storage.store(proofs)
        
        // Mark as pending
        try await storage.markAsPendingSpent(proofs)
        #expect(try await storage.getPendingSpent().count == 5)
        
        // Rollback (failure case)
        try await storage.rollbackPendingSpent(proofs)
        #expect(try await storage.getPendingSpent().count == 0)
        
        // Storage still has all proofs
        #expect(try await storage.count() == 5)
    }
}

// MARK: - ProofManager Tests

@Suite("ProofManager Tests")
struct ProofManagerTests {
    
    // MARK: - Test Helpers
    
    func createTestProof(
        amount: Int = 100,
        id: String = "test_keyset_001",
        secret: String? = nil,
        C: String? = nil
    ) -> Proof {
        let finalSecret = secret ?? UUID().uuidString
        let finalC = C ?? "02" + String(repeating: "ab", count: 32)
        return Proof(
            amount: amount,
            id: id,
            secret: finalSecret,
            C: finalC
        )
    }
    
    // MARK: - Add Proofs Tests
    
    @Test("Add valid proofs")
    func addValidProofs() async throws {
        let manager = ProofManager()
        let proofs = (0..<3).map { createTestProof(amount: ($0 + 1) * 50) }
        
        try await manager.addProofs(proofs)
        
        let count = try await manager.getProofCount()
        #expect(count == 3)
    }
    
    @Test("Add empty proofs array - no error")
    func addEmptyProofsArray() async throws {
        let manager = ProofManager()
        
        try await manager.addProofs([])
        
        let count = try await manager.getProofCount()
        #expect(count == 0)
    }
    
    @Test("Add proof with invalid amount throws")
    func addProofWithInvalidAmount() async throws {
        let manager = ProofManager()
        let invalidProof = Proof(
            amount: 0, // Invalid: must be > 0
            id: "keyset",
            secret: "secret",
            C: "02" + String(repeating: "ab", count: 32)
        )
        
        await #expect(throws: CashuError.self) {
            try await manager.addProofs([invalidProof])
        }
    }
    
    @Test("Add proof with empty secret throws")
    func addProofWithEmptySecret() async throws {
        let manager = ProofManager()
        let invalidProof = Proof(
            amount: 100,
            id: "keyset",
            secret: "", // Invalid: must not be empty
            C: "02" + String(repeating: "ab", count: 32)
        )
        
        await #expect(throws: CashuError.self) {
            try await manager.addProofs([invalidProof])
        }
    }
    
    @Test("Add proof with invalid hex C throws")
    func addProofWithInvalidHexC() async throws {
        let manager = ProofManager()
        let invalidProof = Proof(
            amount: 100,
            id: "keyset",
            secret: "valid_secret",
            C: "invalid_hex_string!"
        )
        
        await #expect(throws: CashuError.self) {
            try await manager.addProofs([invalidProof])
        }
    }
    
    @Test("Add duplicate proof throws")
    func addDuplicateProof() async throws {
        let manager = ProofManager()
        let proof = createTestProof()
        
        try await manager.addProofs([proof])
        
        await #expect(throws: CashuError.self) {
            try await manager.addProofs([proof]) // Same proof again
        }
    }
    
    // MARK: - Get Available Proofs Tests
    
    @Test("Get available proofs excludes spent")
    func getAvailableProofsExcludesSpent() async throws {
        let manager = ProofManager()
        let proofs = (0..<5).map { createTestProof(amount: ($0 + 1) * 10) }
        
        try await manager.addProofs(proofs)
        try await manager.markAsSpent([proofs[0], proofs[1]])
        
        let available = try await manager.getAvailableProofs()
        #expect(available.count == 3)
    }
    
    @Test("Get available proofs excludes pending spent")
    func getAvailableProofsExcludesPendingSpent() async throws {
        let manager = ProofManager()
        let proofs = (0..<5).map { createTestProof(amount: ($0 + 1) * 10) }
        
        try await manager.addProofs(proofs)
        try await manager.markAsPendingSpent([proofs[0], proofs[1]])
        
        let available = try await manager.getAvailableProofs()
        #expect(available.count == 3)
    }
    
    @Test("Get available proofs by keyset ID")
    func getAvailableProofsByKeysetID() async throws {
        let manager = ProofManager()
        let keyset1Proofs = (0..<3).map { _ in createTestProof(amount: 10, id: "keyset_1") }
        let keyset2Proofs = (0..<2).map { _ in createTestProof(amount: 20, id: "keyset_2") }
        
        try await manager.addProofs(keyset1Proofs)
        try await manager.addProofs(keyset2Proofs)
        
        let keyset1Available = try await manager.getAvailableProofs(keysetID: "keyset_1")
        let keyset2Available = try await manager.getAvailableProofs(keysetID: "keyset_2")
        
        #expect(keyset1Available.count == 3)
        #expect(keyset2Available.count == 2)
    }
    
    // MARK: - Balance Tests
    
    @Test("Get total balance")
    func getTotalBalance() async throws {
        let manager = ProofManager()
        let proofs = [
            createTestProof(amount: 100),
            createTestProof(amount: 50),
            createTestProof(amount: 25)
        ]
        
        try await manager.addProofs(proofs)
        
        let balance = try await manager.getTotalBalance()
        #expect(balance == 175)
    }
    
    @Test("Get balance excludes spent proofs")
    func getBalanceExcludesSpent() async throws {
        let manager = ProofManager()
        let proofs = [
            createTestProof(amount: 100),
            createTestProof(amount: 50),
            createTestProof(amount: 25)
        ]
        
        try await manager.addProofs(proofs)
        try await manager.markAsSpent([proofs[0]]) // Mark 100 as spent
        
        let balance = try await manager.getTotalBalance()
        #expect(balance == 75)
    }
    
    @Test("Get balance by keyset ID")
    func getBalanceByKeysetID() async throws {
        let manager = ProofManager()
        let keyset1Proofs = [
            createTestProof(amount: 100, id: "keyset_1"),
            createTestProof(amount: 50, id: "keyset_1")
        ]
        let keyset2Proofs = [
            createTestProof(amount: 200, id: "keyset_2")
        ]
        
        try await manager.addProofs(keyset1Proofs)
        try await manager.addProofs(keyset2Proofs)
        
        let keyset1Balance = try await manager.getBalance(keysetID: "keyset_1")
        let keyset2Balance = try await manager.getBalance(keysetID: "keyset_2")
        
        #expect(keyset1Balance == 150)
        #expect(keyset2Balance == 200)
    }
    
    // MARK: - Select Proofs Tests
    
    @Test("Select proofs for exact amount")
    func selectProofsExactAmount() async throws {
        let manager = ProofManager()
        let proofs = [
            createTestProof(amount: 100),
            createTestProof(amount: 50),
            createTestProof(amount: 25)
        ]
        
        try await manager.addProofs(proofs)
        
        let selected = try await manager.selectProofs(amount: 50)
        #expect(selected.count == 1)
        #expect(selected[0].amount == 50)
    }
    
    @Test("Select proofs for combined amount")
    func selectProofsCombinedAmount() async throws {
        let manager = ProofManager()
        let proofs = [
            createTestProof(amount: 10),
            createTestProof(amount: 20),
            createTestProof(amount: 30),
            createTestProof(amount: 40)
        ]
        
        try await manager.addProofs(proofs)
        
        let selected = try await manager.selectProofs(amount: 60)
        let selectedTotal = selected.reduce(0) { $0 + $1.amount }
        #expect(selectedTotal >= 60)
    }
    
    @Test("Select proofs with overpayment")
    func selectProofsWithOverpayment() async throws {
        let manager = ProofManager()
        let proofs = [
            createTestProof(amount: 100),
            createTestProof(amount: 50)
        ]
        
        try await manager.addProofs(proofs)
        
        // Select 75 - will need to overpay since we only have 50 and 100
        let selected = try await manager.selectProofs(amount: 75)
        let selectedTotal = selected.reduce(0) { $0 + $1.amount }
        #expect(selectedTotal >= 75)
    }
    
    @Test("Select proofs from empty storage throws")
    func selectProofsFromEmptyStorage() async throws {
        let manager = ProofManager()
        
        await #expect(throws: CashuError.self) {
            _ = try await manager.selectProofs(amount: 100)
        }
    }
    
    @Test("Select proofs with insufficient balance throws")
    func selectProofsInsufficientBalance() async throws {
        let manager = ProofManager()
        let proofs = [
            createTestProof(amount: 50),
            createTestProof(amount: 25)
        ]
        
        try await manager.addProofs(proofs)
        
        await #expect(throws: CashuError.self) {
            _ = try await manager.selectProofs(amount: 100)
        }
    }
    
    @Test("Select proofs with zero amount throws")
    func selectProofsZeroAmount() async throws {
        let manager = ProofManager()
        let proof = createTestProof(amount: 100)
        
        try await manager.addProofs([proof])
        
        await #expect(throws: CashuError.self) {
            _ = try await manager.selectProofs(amount: 0)
        }
    }
    
    @Test("Select proofs by keyset ID")
    func selectProofsByKeysetID() async throws {
        let manager = ProofManager()
        let keyset1Proofs = [
            createTestProof(amount: 100, id: "keyset_1"),
            createTestProof(amount: 50, id: "keyset_1")
        ]
        let keyset2Proofs = [
            createTestProof(amount: 200, id: "keyset_2")
        ]
        
        try await manager.addProofs(keyset1Proofs)
        try await manager.addProofs(keyset2Proofs)
        
        let selected = try await manager.selectProofs(amount: 100, keysetID: "keyset_1")
        #expect(selected.allSatisfy { $0.id == "keyset_1" })
    }
    
    @Test("Select proofs by keyset ID with insufficient balance throws")
    func selectProofsByKeysetIDInsufficientBalance() async throws {
        let manager = ProofManager()
        let proofs = [
            createTestProof(amount: 50, id: "keyset_1")
        ]
        
        try await manager.addProofs(proofs)
        
        await #expect(throws: CashuError.self) {
            _ = try await manager.selectProofs(amount: 100, keysetID: "keyset_1")
        }
    }
    
    // MARK: - Remove Proofs Tests
    
    @Test("Remove proofs clears spent tracking")
    func removeProofsClearsSpentTracking() async throws {
        let manager = ProofManager()
        let proofs = (0..<3).map { createTestProof(amount: ($0 + 1) * 10) }
        
        try await manager.addProofs(proofs)
        try await manager.markAsSpent([proofs[0]])
        
        let initialSpentCount = await manager.getSpentProofCount()
        #expect(initialSpentCount == 1)
        
        try await manager.removeProofs([proofs[0]])
        
        let finalSpentCount = await manager.getSpentProofCount()
        #expect(finalSpentCount == 0)
    }
    
    // MARK: - Clear All Tests
    
    @Test("Clear all resets manager state")
    func clearAllResetsState() async throws {
        let manager = ProofManager()
        let proofs = (0..<5).map { createTestProof(amount: $0 + 1) }
        
        try await manager.addProofs(proofs)
        try await manager.markAsSpent([proofs[0]])
        
        try await manager.clearAll()
        
        #expect(try await manager.getProofCount() == 0)
        #expect(try await manager.getTotalBalance() == 0)
        #expect(await manager.getSpentProofCount() == 0)
    }
    
    // MARK: - Concurrent Access Tests
    
    @Test("Concurrent proof additions")
    func concurrentProofAdditions() async throws {
        let manager = ProofManager()
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let proof = Proof(
                        amount: (i + 1) * 10,
                        id: "keyset_\(i)",
                        secret: "secret_\(i)_\(UUID().uuidString)",
                        C: "02" + String(repeating: String(format: "%02x", i), count: 32)
                    )
                    try? await manager.addProofs([proof])
                }
            }
        }
        
        let count = try await manager.getProofCount()
        #expect(count == 10)
    }
    
    @Test("Concurrent proof selections")
    func concurrentProofSelections() async throws {
        let manager = ProofManager()
        let proofs = (0..<100).map { 
            Proof(
                amount: 10,
                id: "keyset",
                secret: "secret_\($0)_\(UUID().uuidString)",
                C: "02" + String(format: "%064x", $0)
            )
        }
        
        try await manager.addProofs(proofs)
        
        var successCount = 0
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    do {
                        let _ = try await manager.selectProofs(amount: 50)
                        return true
                    } catch {
                        return false
                    }
                }
            }
            
            for await success in group {
                if success { successCount += 1 }
            }
        }
        
        // All selections should succeed since we're just reading
        #expect(successCount == 10)
    }
}

// MARK: - Proof Extension Tests

@Suite("Proof Extension Tests")
struct ProofExtensionTests {
    
    @Test("isValidProof with valid proof")
    func isValidProofValid() throws {
        let proof = Proof(
            amount: 100,
            id: "keyset",
            secret: "valid_secret",
            C: "02" + String(repeating: "ab", count: 32)
        )
        
        #expect(proof.isValidProof)
    }
    
    @Test("isValidProof with zero amount")
    func isValidProofZeroAmount() throws {
        let proof = Proof(
            amount: 0,
            id: "keyset",
            secret: "secret",
            C: "02" + String(repeating: "ab", count: 32)
        )
        
        #expect(!proof.isValidProof)
    }
    
    @Test("isValidProof with empty secret")
    func isValidProofEmptySecret() throws {
        let proof = Proof(
            amount: 100,
            id: "keyset",
            secret: "",
            C: "02" + String(repeating: "ab", count: 32)
        )
        
        #expect(!proof.isValidProof)
    }
    
    @Test("isValidProof with invalid hex C")
    func isValidProofInvalidHexC() throws {
        let proof = Proof(
            amount: 100,
            id: "keyset",
            secret: "secret",
            C: "not_valid_hex!"
        )
        
        #expect(!proof.isValidProof)
    }
    
    @Test("denomination property")
    func denominationProperty() throws {
        let proof = Proof(amount: 256, id: "keyset", secret: "s", C: "02abab")
        #expect(proof.denomination == 256)
    }
    
    @Test("belongsTo keyset check")
    func belongsToKeyset() throws {
        let proof = Proof(amount: 100, id: "keyset_1", secret: "s", C: "02abab")
        
        #expect(proof.belongsTo(keysetID: "keyset_1"))
        #expect(!proof.belongsTo(keysetID: "keyset_2"))
    }
}

// MARK: - Collection Extension Tests

@Suite("Proof Collection Extension Tests")
struct ProofCollectionExtensionTests {
    
    @Test("totalValue calculation")
    func totalValueCalculation() throws {
        let proofs = [
            Proof(amount: 100, id: "k", secret: "s1", C: "c1"),
            Proof(amount: 50, id: "k", secret: "s2", C: "c2"),
            Proof(amount: 25, id: "k", secret: "s3", C: "c3")
        ]
        
        #expect(proofs.totalValue == 175)
    }
    
    @Test("totalValue empty collection")
    func totalValueEmptyCollection() throws {
        let proofs: [Proof] = []
        #expect(proofs.totalValue == 0)
    }
    
    @Test("proofs for keyset ID")
    func proofsForKeysetID() throws {
        let proofs = [
            Proof(amount: 100, id: "keyset_1", secret: "s1", C: "c1"),
            Proof(amount: 50, id: "keyset_2", secret: "s2", C: "c2"),
            Proof(amount: 25, id: "keyset_1", secret: "s3", C: "c3")
        ]
        
        let keyset1Proofs = proofs.proofs(for: "keyset_1")
        #expect(keyset1Proofs.count == 2)
        #expect(keyset1Proofs.totalValue == 125)
    }
    
    @Test("groupedByKeyset")
    func groupedByKeyset() throws {
        let proofs = [
            Proof(amount: 100, id: "keyset_1", secret: "s1", C: "c1"),
            Proof(amount: 50, id: "keyset_2", secret: "s2", C: "c2"),
            Proof(amount: 25, id: "keyset_1", secret: "s3", C: "c3"),
            Proof(amount: 75, id: "keyset_2", secret: "s4", C: "c4")
        ]
        
        let grouped = proofs.groupedByKeyset()
        
        #expect(grouped.keys.count == 2)
        #expect(grouped["keyset_1"]?.count == 2)
        #expect(grouped["keyset_2"]?.count == 2)
    }
    
    @Test("keysetIDs unique set")
    func keysetIDsUniqueSet() throws {
        let proofs = [
            Proof(amount: 100, id: "keyset_1", secret: "s1", C: "c1"),
            Proof(amount: 50, id: "keyset_2", secret: "s2", C: "c2"),
            Proof(amount: 25, id: "keyset_1", secret: "s3", C: "c3")
        ]
        
        let keysetIDs = proofs.keysetIDs
        
        #expect(keysetIDs.count == 2)
        #expect(keysetIDs.contains("keyset_1"))
        #expect(keysetIDs.contains("keyset_2"))
    }
}
