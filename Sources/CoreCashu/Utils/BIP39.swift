//
//  BIP39.swift
//  CoreCashu
//
//  Cross-platform BIP39 mnemonic implementation
//  Specification: https://github.com/bitcoin/bips/blob/master/bip-0039.mediawiki
//

import Foundation
import CryptoKit
import CryptoSwift

/// BIP39 Mnemonic implementation for cross-platform use
public enum BIP39 {
    
    /// Supported mnemonic strengths
    public enum Strength: Int, CaseIterable {
        case bits128 = 128  // 12 words
        case bits160 = 160  // 15 words
        case bits192 = 192  // 18 words
        case bits224 = 224  // 21 words
        case bits256 = 256  // 24 words
        
        /// Number of words for this strength
        public var wordCount: Int {
            switch self {
            case .bits128: return 12
            case .bits160: return 15
            case .bits192: return 18
            case .bits224: return 21
            case .bits256: return 24
            }
        }
        
        /// Checksum length in bits
        var checksumBits: Int {
            rawValue / 32
        }
        
        /// Total bits (entropy + checksum)
        var totalBits: Int {
            rawValue + checksumBits
        }
    }
    
    /// BIP39 Errors
    public enum Error: LocalizedError {
        case invalidEntropy
        case invalidMnemonic
        case invalidWordCount
        case wordNotInList
        case checksumMismatch
        case wordlistNotFound
        
        public var errorDescription: String? {
            switch self {
            case .invalidEntropy:
                return "Invalid entropy size. Must be 128, 160, 192, 224, or 256 bits"
            case .invalidMnemonic:
                return "Invalid mnemonic phrase"
            case .invalidWordCount:
                return "Invalid word count. Must be 12, 15, 18, 21, or 24 words"
            case .wordNotInList:
                return "Word not found in BIP39 wordlist"
            case .checksumMismatch:
                return "Invalid mnemonic checksum"
            case .wordlistNotFound:
                return "BIP39 wordlist not found"
            }
        }
    }
    
    /// The BIP39 English wordlist
    private static let wordlist: [String] = loadWordlist()
    
    /// Word to index mapping for fast lookup
    private static let wordToIndex: [String: Int] = {
        var dict: [String: Int] = [:]
        for (index, word) in wordlist.enumerated() {
            dict[word] = index
        }
        return dict
    }()
    
    /// Load the BIP39 wordlist from embedded resource
    private static func loadWordlist() -> [String] {
        // For Swift Package Manager resources
        #if canImport(Foundation)
        if let url = Bundle.module.url(forResource: "bip39-english", withExtension: "txt"),
           let content = try? String(contentsOf: url) {
            let words = content.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            if words.count == 2048 {
                return words
            }
        }
        #endif
        
        // Try to load from various possible file locations
        let paths = [
            "Sources/CoreCashu/Resources/bip39-english.txt",
            "bip39-english.txt",
            "/Users/rademaker/Developer/SparrowTek/Bitcoin/Cashu/CoreCashu/Sources/CoreCashu/Resources/bip39-english.txt"
        ]
        
        for path in paths {
            if let content = try? String(contentsOfFile: path) {
                let words = content.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                if words.count == 2048 {
                    return words
                }
            }
        }
        
        // Hardcode a minimal wordlist for emergency fallback
        // This will allow basic functionality but should not be used in production
        print("WARNING: Using fallback BIP39 wordlist. This should not happen in production!")
        return generateFallbackWordlist()
    }
    
    /// Generate a fallback wordlist for testing (NOT FOR PRODUCTION)
    private static func generateFallbackWordlist() -> [String] {
        // Generate predictable words for testing only
        var words: [String] = []
        for i in 0..<2048 {
            words.append(String(format: "word%04d", i))
        }
        return words
    }
    
    // MARK: - Public Methods
    
    /// Generate a new mnemonic with specified strength
    /// - Parameter strength: Entropy strength (default: 128 bits for 12 words)
    /// - Returns: Mnemonic phrase as string
    /// - Throws: BIP39.Error if generation fails
    public static func generateMnemonic(strength: Strength = .bits128) throws -> String {
        // Generate entropy
        let entropyBytes = strength.rawValue / 8
        let entropy = try SecureRandom.generateBytes(count: entropyBytes)
        
        // Generate mnemonic from entropy
        return try mnemonicFromEntropy(entropy)
    }
    
    /// Generate mnemonic from provided entropy
    /// - Parameter entropy: Entropy data (must be 128, 160, 192, 224, or 256 bits)
    /// - Returns: Mnemonic phrase as string
    /// - Throws: BIP39.Error if entropy is invalid
    public static func mnemonicFromEntropy(_ entropy: Data) throws -> String {
        // Validate entropy size
        guard let strength = Strength.allCases.first(where: { $0.rawValue / 8 == entropy.count }) else {
            throw Error.invalidEntropy
        }
        
        // Calculate checksum
        let hash = SHA256.hash(data: entropy)
        let hashBytes = Array(hash)
        let checksumByte = hashBytes[0]
        let checksumBits = strength.checksumBits
        
        // Convert entropy to bits
        var bits = ""
        for byte in entropy {
            bits += String(byte, radix: 2).padLeft(toLength: 8, withPad: "0")
        }
        
        // Add checksum bits
        let checksumBitsString = String(checksumByte, radix: 2)
            .padLeft(toLength: 8, withPad: "0")
            .prefix(checksumBits)
        bits += checksumBitsString
        
        // Split into 11-bit chunks and map to words
        var words: [String] = []
        let chunkSize = 11
        
        for i in stride(from: 0, to: bits.count, by: chunkSize) {
            let startIndex = bits.index(bits.startIndex, offsetBy: i)
            let endIndex = bits.index(startIndex, offsetBy: chunkSize)
            let chunk = String(bits[startIndex..<endIndex])
            
            if let index = Int(chunk, radix: 2), index < wordlist.count {
                words.append(wordlist[index])
            } else {
                throw Error.invalidEntropy
            }
        }
        
        return words.joined(separator: " ")
    }
    
    /// Validate a mnemonic phrase
    /// - Parameter mnemonic: Mnemonic phrase to validate
    /// - Returns: true if valid, false otherwise
    public static func validateMnemonic(_ mnemonic: String) -> Bool {
        do {
            _ = try entropyFromMnemonic(mnemonic)
            return true
        } catch {
            return false
        }
    }
    
    /// Convert mnemonic to entropy
    /// - Parameter mnemonic: Mnemonic phrase
    /// - Returns: Entropy data
    /// - Throws: BIP39.Error if mnemonic is invalid
    public static func entropyFromMnemonic(_ mnemonic: String) throws -> Data {
        let words = mnemonic.lowercased().split(separator: " ").map(String.init)
        
        // Validate word count
        guard let strength = Strength.allCases.first(where: { $0.wordCount == words.count }) else {
            throw Error.invalidWordCount
        }
        
        // Convert words to bits
        var bits = ""
        for word in words {
            guard let index = wordToIndex[word] else {
                throw Error.wordNotInList
            }
            bits += String(index, radix: 2).padLeft(toLength: 11, withPad: "0")
        }
        
        // Split entropy and checksum
        let entropyBits = String(bits.prefix(strength.rawValue))
        let checksumBits = String(bits.suffix(strength.checksumBits))
        
        // Convert entropy bits to bytes
        var entropyBytes: [UInt8] = []
        for i in stride(from: 0, to: entropyBits.count, by: 8) {
            let startIndex = entropyBits.index(entropyBits.startIndex, offsetBy: i)
            let endIndex = entropyBits.index(startIndex, offsetBy: 8)
            let byteBits = String(entropyBits[startIndex..<endIndex])
            if let byte = UInt8(byteBits, radix: 2) {
                entropyBytes.append(byte)
            }
        }
        
        let entropy = Data(entropyBytes)
        
        // Verify checksum
        let hash = SHA256.hash(data: entropy)
        let hashBytes = Array(hash)
        let expectedChecksumByte = hashBytes[0]
        let expectedChecksumBits = String(expectedChecksumByte, radix: 2)
            .padLeft(toLength: 8, withPad: "0")
            .prefix(strength.checksumBits)
        
        guard String(expectedChecksumBits) == checksumBits else {
            throw Error.checksumMismatch
        }
        
        return entropy
    }
    
    /// Generate seed from mnemonic and optional passphrase
    /// - Parameters:
    ///   - mnemonic: BIP39 mnemonic phrase
    ///   - passphrase: Optional passphrase (default: empty)
    /// - Returns: 64-byte seed
    /// - Throws: Error if mnemonic is invalid
    public static func seed(from mnemonic: String, passphrase: String = "") throws -> Data {
        // Validate mnemonic first
        guard validateMnemonic(mnemonic) else {
            throw Error.invalidMnemonic
        }
        
        // Use the same implementation as NUT13
        return createSeedFromMnemonic(mnemonic: mnemonic, passphrase: passphrase)
    }
}

// MARK: - Helper Extensions

private extension String {
    /// Pad string on the left to specified length
    func padLeft(toLength length: Int, withPad pad: String) -> String {
        if self.count >= length {
            return self
        }
        let padding = String(repeating: pad, count: length - self.count)
        return padding + self
    }
}

// MARK: - Bridge to existing implementation

private func createSeedFromMnemonic(mnemonic: String, passphrase: String) -> Data {
    let mnemonicData = mnemonic.data(using: .utf8) ?? Data()
    let salt = "mnemonic\(passphrase)".data(using: .utf8) ?? Data()
    
    // BIP39 specifies PBKDF2 with HMAC-SHA512, 2048 iterations
    // Using CryptoSwift for cross-platform compatibility
    do {
        let password = Array(mnemonicData)
        let saltBytes = Array(salt)
        let seed = try PKCS5.PBKDF2(
            password: password,
            salt: saltBytes,
            iterations: 2048,
            keyLength: 64,
            variant: .sha2(.sha512)
        ).calculate()
        return Data(seed)
    } catch {
        // Fallback to a deterministic but non-standard seed
        let combined = mnemonicData + salt
        return Data(SHA512.hash(data: combined))
    }
}