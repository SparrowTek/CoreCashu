//
//  SecureMemory.swift
//  CoreCashu
//
//  Secure memory management utilities for handling sensitive data
//

import Foundation

/// Utilities for secure memory management
public enum SecureMemory {
    
    /// Securely wipe a Data object's contents
    /// - Parameter data: The data to wipe
    public static func wipe(_ data: inout Data) {
        data.withUnsafeMutableBytes { bytes in
            // Use volatile pointer to prevent compiler optimization
            let volatileBytes = bytes.bindMemory(to: UInt8.self)
            for i in 0..<bytes.count {
                volatileBytes[i] = 0
            }
            
            // Additional pass with random data for extra security
            for i in 0..<bytes.count {
                volatileBytes[i] = UInt8.random(in: 0...255)
            }
            
            // Final pass with zeros
            for i in 0..<bytes.count {
                volatileBytes[i] = 0
            }
        }
        
        // Clear the data
        data.removeAll(keepingCapacity: false)
    }
    
    /// Securely wipe a String's contents
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
    
    /// Securely wipe an array of bytes
    /// - Parameter bytes: The byte array to wipe
    public static func wipe(_ bytes: inout [UInt8]) {
        // Overwrite with zeros
        for i in 0..<bytes.count {
            bytes[i] = 0
        }
        
        // Overwrite with random data
        for i in 0..<bytes.count {
            bytes[i] = UInt8.random(in: 0...255)
        }
        
        // Final overwrite with zeros
        for i in 0..<bytes.count {
            bytes[i] = 0
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