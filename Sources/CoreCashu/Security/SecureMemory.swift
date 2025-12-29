//
//  SecureMemory.swift
//  CoreCashu
//
//  Secure memory management utilities for handling sensitive data
//

import Foundation

/// Utilities for best-effort secure memory management. These routines overwrite buffers with
/// multiple patterns (zero, random, zero) to reduce the likelihood of residual secrets but cannot
/// guarantee hardware-level zeroization in the presence of compiler or hardware reordering.
public enum SecureMemory {
    
    /// Securely wipe a Data object's contents (best effort)
    /// - Parameter data: The data to wipe
    public static func wipe(_ data: inout Data) {
        data.withUnsafeMutableBytes { bytes in
            // Use volatile pointer to prevent compiler optimization
            let volatileBytes = bytes.bindMemory(to: UInt8.self)
            overwrite(volatileBytes, with: 0)
            overwriteWithSecureRandom(volatileBytes)
            overwrite(volatileBytes, with: 0)
        }
        
        // Clear the data
        data.removeAll(keepingCapacity: false)
    }
    
    /// Securely wipe a String's contents (best effort)
    /// - Parameter string: The string to wipe
    public static func wipe(_ string: inout String) {
        // Convert to mutable data
        if var data = string.data(using: .utf8) {
            wipe(&data)
        }
        
        // Clear the string
        string.removeAll(keepingCapacity: false)
        string = ""
    }
    
    /// Securely wipe an array of bytes (best effort)
    /// - Parameter bytes: The byte array to wipe
    public static func wipe(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBufferPointer { buffer in
            overwrite(buffer, with: 0)
            overwriteWithSecureRandom(buffer)
            overwrite(buffer, with: 0)
        }
        
        // Clear the array
        bytes.removeAll(keepingCapacity: false)
    }
    
    /// Execute a closure with temporary sensitive data that is automatically wiped
    /// - Parameters:
    ///   - data: The sensitive data
    ///   - block: The closure to execute with the data
    /// - Returns: The result of the closure
    public static func withSecureData<T>(_ data: Data, block: (Data) throws -> T) rethrows -> T {
        var mutableData = data
        defer {
            wipe(&mutableData)
        }
        return try block(mutableData)
    }
    
    /// Execute a closure with temporary sensitive string that is automatically wiped
    /// - Parameters:
    ///   - string: The sensitive string
    ///   - block: The closure to execute with the string
    /// - Returns: The result of the closure
    public static func withSecureString<T>(_ string: String, block: (String) throws -> T) rethrows -> T {
        var mutableString = string
        defer {
            wipe(&mutableString)
        }
        return try block(mutableString)
    }
}

// MARK: - Helpers

private extension SecureMemory {
    static func overwrite(_ buffer: UnsafeMutableBufferPointer<UInt8>, with value: UInt8) {
        for index in buffer.indices {
            buffer[index] = value
        }
    }
    
    static func overwriteWithSecureRandom(_ buffer: UnsafeMutableBufferPointer<UInt8>) {
        guard buffer.count > 0 else { return }
        if let randomBytes = try? SecureRandom.generateBytes(count: buffer.count) {
            for (index, byte) in randomBytes.enumerated() {
                buffer[index] = byte
            }
        } else {
            // Fallback pattern ensures data is mutated even if randomness fails
            overwrite(buffer, with: 0xAA)
        }
    }
}

// MARK: - Constant-Time Comparison

extension SecureMemory {
    /// Constant-time comparison of two Data objects to prevent timing attacks.
    /// Returns true if both Data objects have the same length and contents.
    /// This function runs in time proportional to the length of the inputs,
    /// regardless of where (or if) the first difference occurs.
    ///
    /// - Parameters:
    ///   - lhs: First data to compare
    ///   - rhs: Second data to compare
    /// - Returns: true if equal, false otherwise
    public static func constantTimeCompare(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }
        
        // XOR all bytes and OR the results. If any byte differs, result will be non-zero.
        var result: UInt8 = 0
        for (l, r) in zip(lhs, rhs) {
            result |= l ^ r
        }
        
        return result == 0
    }
    
    /// Constant-time comparison of two byte arrays to prevent timing attacks.
    /// - Parameters:
    ///   - lhs: First array to compare
    ///   - rhs: Second array to compare
    /// - Returns: true if equal, false otherwise
    public static func constantTimeCompare(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }
        
        var result: UInt8 = 0
        for (l, r) in zip(lhs, rhs) {
            result |= l ^ r
        }
        
        return result == 0
    }
}

/// A wrapper for sensitive data that automatically wipes on deinitialization
public final class SensitiveData: @unchecked Sendable {
    private var data: Data
    private let lock = NSLock()
    
    public init(_ data: Data) {
        self.data = data
    }
    
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return data.count
    }
    
    public func withData<T>(_ block: (Data) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try block(data)
    }
    
    deinit {
        lock.lock()
        defer { lock.unlock() }
        SecureMemory.wipe(&data)
    }
}

/// A wrapper for sensitive strings that automatically wipes on deinitialization
public final class SensitiveString: @unchecked Sendable {
    private var string: String
    private let lock = NSLock()
    
    public init(_ string: String) {
        self.string = string
    }
    
    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return string.isEmpty
    }
    
    public func withString<T>(_ block: (String) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try block(string)
    }
    
    deinit {
        lock.lock()
        defer { lock.unlock() }
        SecureMemory.wipe(&string)
    }
}
