//
//  CryptoLock.swift
//  CoreCashu
//
//  Global lock for P256K/secp256k1 operations to ensure thread safety.
//  libsecp256k1 can have race conditions when accessed concurrently.
//

import Foundation

/// Global lock for serializing access to P256K/secp256k1 operations
/// This is necessary because libsecp256k1 may not be fully thread-safe
/// for all operations, particularly during concurrent test execution.
/// Uses NSRecursiveLock to allow nested calls from the same thread.
public final class CryptoLock: @unchecked Sendable {
    public static let shared = CryptoLock()

    private let lock = NSRecursiveLock()

    private init() {}

    /// Execute a block while holding the crypto lock
    /// - Parameter block: The block to execute
    /// - Returns: The result of the block
    @discardableResult
    public func withLock<T>(_ block: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try block()
    }
}
