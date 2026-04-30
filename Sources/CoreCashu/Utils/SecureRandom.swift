//
//  SecureRandom.swift
//  CoreCashu
//
//  Cross-platform secure random number generation
//

import Foundation
#if canImport(Security)
import Security
#endif

/// Cross-platform secure random bytes generation
public enum SecureRandom {
    private enum TaskScopedGenerator {
        @TaskLocal static var generator: (@Sendable (_ count: Int) throws -> Data)?
    }

    /// Execute an operation with a task-scoped random byte generator override.
    /// This avoids leaking deterministic generators into concurrently running tests.
    public static func withGenerator<R>(
        _ generator: @escaping @Sendable (_ count: Int) throws -> Data,
        operation: () throws -> R
    ) rethrows -> R {
        try TaskScopedGenerator.$generator.withValue(generator) {
            try operation()
        }
    }

    /// Async variant of `withGenerator(_:operation:)`.
    public static func withGenerator<R>(
        _ generator: @escaping @Sendable (_ count: Int) throws -> Data,
        operation: () async throws -> R
    ) async rethrows -> R {
        try await TaskScopedGenerator.$generator.withValue(generator) {
            try await operation()
        }
    }
    
    /// Generate cryptographically secure random bytes
    /// - Parameter count: Number of bytes to generate
    /// - Returns: Random bytes as Data
    /// - Throws: Error if generation fails
    public static func generateBytes(count: Int) throws -> Data {
        if let generator = TaskScopedGenerator.generator {
            return try generator(count)
        }
        
        #if canImport(Security)
        // Use Security framework on Apple platforms
        
        var bytes = Data(count: count)
        let result = bytes.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
        }
        
        guard result == errSecSuccess else {
            throw CashuError.keyGenerationFailed
        }
        
        return bytes
        #else
        // Use CryptoKit's RandomNumberGenerator on other platforms
        var generator = SystemRandomNumberGenerator()
        var bytes = Data(count: count)
        
        for i in 0..<count {
            bytes[i] = generator.next()
        }
        
        return bytes
        #endif
    }
    
    /// Generate a random 32-byte key
    /// - Returns: 32 random bytes as Data
    /// - Throws: Error if generation fails
    public static func generateKey() throws -> Data {
        try generateBytes(count: 32)
    }
    
    /// Generate a random 16-byte nonce
    /// - Returns: 16 random bytes as Data
    /// - Throws: Error if generation fails
    public static func generateNonce() throws -> Data {
        try generateBytes(count: 16)
    }
}

