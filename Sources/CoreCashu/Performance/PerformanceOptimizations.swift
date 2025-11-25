//
//  PerformanceOptimizations.swift
//  CashuKit
//
//  Consolidated performance optimizations
//

import Foundation
import CryptoKit
@preconcurrency import P256K

// MARK: - Simple Cache Implementation

/// Simple cache for performance optimization
public actor SimpleCache<Key: Hashable & Sendable, Value: Sendable> {
    private var storage: [Key: (value: Value, lastAccess: Date)] = [:]
    private let maxSize: Int
    private let ttl: TimeInterval?
    
    public init(maxSize: Int = 1000, ttl: TimeInterval? = nil) {
        self.maxSize = maxSize
        self.ttl = ttl
    }
    
    public func get(_ key: Key) -> Value? {
        guard let entry = storage[key] else { return nil }
        
        // Check TTL
        if let ttl = ttl, Date().timeIntervalSince(entry.lastAccess) > ttl {
            storage.removeValue(forKey: key)
            return nil
        }
        
        // Update last access
        storage[key] = (value: entry.value, lastAccess: Date())
        return entry.value
    }
    
    public func set(_ key: Key, value: Value) {
        storage[key] = (value: value, lastAccess: Date())
        
        // Evict if needed
        if storage.count > maxSize {
            // Remove oldest entry
            if let oldestKey = storage.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
                storage.removeValue(forKey: oldestKey)
            }
        }
    }
    
    public func clear() {
        storage.removeAll()
    }
}

// MARK: - Optimized Crypto Operations

/// Optimized cryptographic operations
public struct OptimizedCrypto: Sendable {
    /// Actor-isolated cache for hash-to-curve operations
    private actor HashToCurveCache {
        private var storage: [String: (value: Data, lastAccess: Date)] = [:]
        private let maxSize: Int = 10000
        private let ttl: TimeInterval = 3600 // 1 hour

        func get(_ key: String) -> Data? {
            guard let entry = storage[key] else { return nil }

            // Check TTL
            if Date().timeIntervalSince(entry.lastAccess) > ttl {
                storage.removeValue(forKey: key)
                return nil
            }

            // Update last access
            storage[key] = (value: entry.value, lastAccess: Date())
            return entry.value
        }

        func set(_ key: String, value: Data) {
            storage[key] = (value: value, lastAccess: Date())

            // Evict if needed
            if storage.count > maxSize {
                if let oldestKey = storage.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
                    storage.removeValue(forKey: oldestKey)
                }
            }
        }
    }

    /// Cached hash-to-curve operations (stores raw bytes for Sendable compliance)
    private static let hashToCurveCache = HashToCurveCache()

    /// Hash to curve with caching
    public static func cachedHashToCurve(_ data: Data) async throws -> P256K.KeyAgreement.PublicKey {
        let key = data.hexString

        if let cachedData = await hashToCurveCache.get(key) {
            return try P256K.KeyAgreement.PublicKey(dataRepresentation: cachedData, format: .compressed)
        }

        let result = try hashToCurve(data)
        let resultData = result.dataRepresentation
        await hashToCurveCache.set(key, value: resultData)

        return result
    }
    
    /// Batch processing for multiple operations
    public static func batchProcess<T: Sendable, R: Sendable>(
        items: [T],
        maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        operation: @escaping @Sendable (T) async throws -> R
    ) async throws -> [R] {
        try await withThrowingTaskGroup(of: (Int, R).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask {
                    let result = try await operation(item)
                    return (index, result)
                }
            }
            
            var results = Array<R?>(repeating: nil, count: items.count)
            for try await (index, result) in group {
                results[index] = result
            }
            
            return results.compactMap { $0 }
        }
    }
}

// MARK: - Memory-Efficient Proof Storage

/// In-memory proof storage with efficient indexing
public actor OptimizedProofStorage {
    private var proofs: [UUID: Proof] = [:]
    private var amountIndex: [Int: Set<UUID>] = [:]
    private var keysetIndex: [String: Set<UUID>] = [:]
    private var spentProofs: Set<UUID> = []
    
    public init() {}
    
    public func store(_ proof: Proof) async -> UUID {
        let id = UUID()
        proofs[id] = proof
        
        // Update indices
        amountIndex[proof.amount, default: []].insert(id)
        keysetIndex[proof.id, default: []].insert(id)
        
        return id
    }
    
    public func markAsSpent(_ id: UUID) async {
        spentProofs.insert(id)
    }
    
    public func getUnspentProofs(amount: Int? = nil, keysetId: String? = nil) async -> [Proof] {
        var candidateIds = Set(proofs.keys).subtracting(spentProofs)
        
        if let amount = amount {
            candidateIds = candidateIds.intersection(amountIndex[amount] ?? [])
        }
        
        if let keysetId = keysetId {
            candidateIds = candidateIds.intersection(keysetIndex[keysetId] ?? [])
        }
        
        return candidateIds.compactMap { proofs[$0] }
    }
    
    public func selectProofsForAmount(_ targetAmount: Int) async -> [Proof]? {
        let unspentProofs = await getUnspentProofs()
        return selectOptimalProofs(from: unspentProofs, targetAmount: targetAmount)
    }
    
    private func selectOptimalProofs(from proofs: [Proof], targetAmount: Int) -> [Proof]? {
        // Try exact match first
        if let exactMatch = proofs.first(where: { $0.amount == targetAmount }) {
            return [exactMatch]
        }
        
        // Simple greedy algorithm
        let sorted = proofs.sorted { $0.amount > $1.amount }
        var selected: [Proof] = []
        var currentSum = 0
        
        for proof in sorted {
            if currentSum + proof.amount <= targetAmount {
                selected.append(proof)
                currentSum += proof.amount
                
                if currentSum == targetAmount {
                    return selected
                }
            }
        }
        
        return currentSum == targetAmount ? selected : nil
    }
}

// MARK: - Performance Monitoring

/// Simple performance monitor
public struct PerformanceMonitor {
    private let startTime: CFAbsoluteTime
    private let operation: String
    
    public init(operation: String) {
        self.operation = operation
        self.startTime = CFAbsoluteTimeGetCurrent()
    }
    
    public func end() {
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        print("[Performance] \(operation): \(String(format: "%.3f", elapsed * 1000))ms")
    }
}

// MARK: - Performance Manager

/// Performance manager using actors for thread-safe caching
/// Note: This is an actor rather than struct to properly handle actor-isolated properties
public actor PerformanceManager {
    public let proofStorage: OptimizedProofStorage
    private let mintInfoCache: SimpleCache<String, MintInfo>
    private let keysetCache: SimpleCache<String, Keyset>

    public init(
        maxMintInfoCacheSize: Int = 100,
        mintInfoCacheTTL: TimeInterval = 3600,
        maxKeysetCacheSize: Int = 500,
        keysetCacheTTL: TimeInterval = 7200
    ) {
        self.proofStorage = OptimizedProofStorage()
        self.mintInfoCache = SimpleCache<String, MintInfo>(
            maxSize: maxMintInfoCacheSize,
            ttl: mintInfoCacheTTL
        )
        self.keysetCache = SimpleCache<String, Keyset>(
            maxSize: maxKeysetCacheSize,
            ttl: keysetCacheTTL
        )
    }

    public func getCachedMintInfo(_ key: String) async -> MintInfo? {
        await mintInfoCache.get(key)
    }

    public func setCachedMintInfo(_ key: String, value: MintInfo) async {
        await mintInfoCache.set(key, value: value)
    }

    public func getCachedKeyset(_ key: String) async -> Keyset? {
        await keysetCache.get(key)
    }

    public func setCachedKeyset(_ key: String, value: Keyset) async {
        await keysetCache.set(key, value: value)
    }
}

// MARK: - Integration Helpers

extension CashuWallet {
    /// Get cached mint info using the wallet's performance manager
    public func getCachedMintInfo(for url: String) async -> MintInfo? {
        // This would need to be implemented with a performanceManager property on CashuWallet
        // For now, return nil to maintain compatibility
        return nil
    }
    
    /// Cache mint info using the wallet's performance manager
    public func cacheMintInfo(_ info: MintInfo, for url: String) async {
        // This would need to be implemented with a performanceManager property on CashuWallet
        // For now, no-op to maintain compatibility
    }
}

// MARK: - Utility Extensions
// Note: hexString is already defined in Extensions.swift