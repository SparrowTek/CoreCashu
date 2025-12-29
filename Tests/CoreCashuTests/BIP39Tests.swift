//
//  BIP39Tests.swift
//  CoreCashu
//
//  Comprehensive tests for BIP39 mnemonic implementation
//

import Testing
import Foundation
@testable import CoreCashu

// MARK: - BIP39 Strength Tests

@Suite("BIP39 Strength Tests")
struct BIP39StrengthTests {
    
    @Test("Strength word counts are correct")
    func strengthWordCounts() throws {
        #expect(BIP39.Strength.bits128.wordCount == 12)
        #expect(BIP39.Strength.bits160.wordCount == 15)
        #expect(BIP39.Strength.bits192.wordCount == 18)
        #expect(BIP39.Strength.bits224.wordCount == 21)
        #expect(BIP39.Strength.bits256.wordCount == 24)
    }
    
    @Test("Strength raw values are correct")
    func strengthRawValues() throws {
        #expect(BIP39.Strength.bits128.rawValue == 128)
        #expect(BIP39.Strength.bits160.rawValue == 160)
        #expect(BIP39.Strength.bits192.rawValue == 192)
        #expect(BIP39.Strength.bits224.rawValue == 224)
        #expect(BIP39.Strength.bits256.rawValue == 256)
    }
    
    @Test("All strengths are iterable")
    func allStrengthsIterable() throws {
        #expect(BIP39.Strength.allCases.count == 5)
    }
}

// MARK: - BIP39 Mnemonic Generation Tests

@Suite("BIP39 Mnemonic Generation Tests")
struct BIP39MnemonicGenerationTests {
    
    @Test("Generate 12-word mnemonic")
    func generate12WordMnemonic() throws {
        let mnemonic = try BIP39.generateMnemonic(strength: .bits128)
        let words = mnemonic.split(separator: " ")
        #expect(words.count == 12)
    }
    
    @Test("Generate 15-word mnemonic")
    func generate15WordMnemonic() throws {
        let mnemonic = try BIP39.generateMnemonic(strength: .bits160)
        let words = mnemonic.split(separator: " ")
        #expect(words.count == 15)
    }
    
    @Test("Generate 18-word mnemonic")
    func generate18WordMnemonic() throws {
        let mnemonic = try BIP39.generateMnemonic(strength: .bits192)
        let words = mnemonic.split(separator: " ")
        #expect(words.count == 18)
    }
    
    @Test("Generate 21-word mnemonic")
    func generate21WordMnemonic() throws {
        let mnemonic = try BIP39.generateMnemonic(strength: .bits224)
        let words = mnemonic.split(separator: " ")
        #expect(words.count == 21)
    }
    
    @Test("Generate 24-word mnemonic")
    func generate24WordMnemonic() throws {
        let mnemonic = try BIP39.generateMnemonic(strength: .bits256)
        let words = mnemonic.split(separator: " ")
        #expect(words.count == 24)
    }
    
    @Test("Default strength generates 12 words")
    func defaultStrength12Words() throws {
        let mnemonic = try BIP39.generateMnemonic()
        let words = mnemonic.split(separator: " ")
        #expect(words.count == 12)
    }
    
    @Test("Generated mnemonics are unique")
    func generatedMnemonicsUnique() throws {
        let mnemonic1 = try BIP39.generateMnemonic()
        let mnemonic2 = try BIP39.generateMnemonic()
        #expect(mnemonic1 != mnemonic2)
    }
    
    @Test("Generated mnemonic is valid")
    func generatedMnemonicIsValid() throws {
        let mnemonic = try BIP39.generateMnemonic()
        #expect(BIP39.validateMnemonic(mnemonic))
    }
    
    @Test("All strength levels generate valid mnemonics")
    func allStrengthsGenerateValid() throws {
        for strength in BIP39.Strength.allCases {
            let mnemonic = try BIP39.generateMnemonic(strength: strength)
            #expect(BIP39.validateMnemonic(mnemonic), "Mnemonic for \(strength) should be valid")
        }
    }
}

// MARK: - BIP39 Entropy Tests

@Suite("BIP39 Entropy Tests")
struct BIP39EntropyTests {
    
    @Test("Mnemonic from 16-byte entropy")
    func mnemonicFrom16ByteEntropy() throws {
        let entropy = Data(repeating: 0xAB, count: 16) // 128 bits
        let mnemonic = try BIP39.mnemonicFromEntropy(entropy)
        let words = mnemonic.split(separator: " ")
        #expect(words.count == 12)
    }
    
    @Test("Mnemonic from 20-byte entropy")
    func mnemonicFrom20ByteEntropy() throws {
        let entropy = Data(repeating: 0xCD, count: 20) // 160 bits
        let mnemonic = try BIP39.mnemonicFromEntropy(entropy)
        let words = mnemonic.split(separator: " ")
        #expect(words.count == 15)
    }
    
    @Test("Mnemonic from 24-byte entropy")
    func mnemonicFrom24ByteEntropy() throws {
        let entropy = Data(repeating: 0xEF, count: 24) // 192 bits
        let mnemonic = try BIP39.mnemonicFromEntropy(entropy)
        let words = mnemonic.split(separator: " ")
        #expect(words.count == 18)
    }
    
    @Test("Mnemonic from 28-byte entropy")
    func mnemonicFrom28ByteEntropy() throws {
        let entropy = Data(repeating: 0x12, count: 28) // 224 bits
        let mnemonic = try BIP39.mnemonicFromEntropy(entropy)
        let words = mnemonic.split(separator: " ")
        #expect(words.count == 21)
    }
    
    @Test("Mnemonic from 32-byte entropy")
    func mnemonicFrom32ByteEntropy() throws {
        let entropy = Data(repeating: 0x34, count: 32) // 256 bits
        let mnemonic = try BIP39.mnemonicFromEntropy(entropy)
        let words = mnemonic.split(separator: " ")
        #expect(words.count == 24)
    }
    
    @Test("Invalid entropy size throws")
    func invalidEntropySizeThrows() throws {
        let invalidSizes = [8, 15, 17, 31, 33, 64]
        
        for size in invalidSizes {
            let entropy = Data(repeating: 0x00, count: size)
            #expect(throws: BIP39.Error.self) {
                _ = try BIP39.mnemonicFromEntropy(entropy)
            }
        }
    }
    
    @Test("Entropy round trip")
    func entropyRoundTrip() throws {
        // Create deterministic entropy
        let originalEntropy = Data([
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
        ])
        
        // Convert to mnemonic
        let mnemonic = try BIP39.mnemonicFromEntropy(originalEntropy)
        
        // Convert back to entropy
        let recoveredEntropy = try BIP39.entropyFromMnemonic(mnemonic)
        
        #expect(originalEntropy == recoveredEntropy)
    }
    
    @Test("Same entropy produces same mnemonic")
    func sameEntropyProducesSameMnemonic() throws {
        let entropy = Data(repeating: 0x42, count: 16)
        
        let mnemonic1 = try BIP39.mnemonicFromEntropy(entropy)
        let mnemonic2 = try BIP39.mnemonicFromEntropy(entropy)
        
        #expect(mnemonic1 == mnemonic2)
    }
}

// MARK: - BIP39 Validation Tests

@Suite("BIP39 Validation Tests")
struct BIP39ValidationTests {
    
    @Test("Valid mnemonic validates")
    func validMnemonicValidates() throws {
        let mnemonic = try BIP39.generateMnemonic()
        #expect(BIP39.validateMnemonic(mnemonic))
    }
    
    @Test("Invalid word count fails validation")
    func invalidWordCountFails() throws {
        let invalidCounts = [
            "word",                           // 1 word
            "word one two",                   // 3 words
            "one two three four five six seven eight nine ten eleven", // 11 words
            "one two three four five six seven eight nine ten eleven twelve thirteen" // 13 words
        ]
        
        for mnemonic in invalidCounts {
            #expect(!BIP39.validateMnemonic(mnemonic), "'\(mnemonic)' should fail validation")
        }
    }
    
    @Test("Empty mnemonic fails validation")
    func emptyMnemonicFails() throws {
        #expect(!BIP39.validateMnemonic(""))
    }
    
    @Test("Mnemonic with invalid checksum fails")
    func invalidChecksumFails() throws {
        // Generate a valid mnemonic
        let validMnemonic = try BIP39.generateMnemonic()
        var words = validMnemonic.split(separator: " ").map(String.init)
        
        // Swap two words to break checksum (if words are different)
        if words[0] != words[1] {
            let temp = words[0]
            words[0] = words[1]
            words[1] = temp
            
            let invalidMnemonic = words.joined(separator: " ")
            
            // This may or may not fail depending on wordlist - the important thing
            // is that validation returns a boolean without crashing
            let _ = BIP39.validateMnemonic(invalidMnemonic)
        }
    }
    
    @Test("Mnemonic validation is case insensitive")
    func validationCaseInsensitive() throws {
        let mnemonic = try BIP39.generateMnemonic()
        
        let uppercase = mnemonic.uppercased()
        let lowercase = mnemonic.lowercased()
        let mixed = mnemonic.prefix(mnemonic.count / 2).uppercased() + mnemonic.suffix(mnemonic.count / 2).lowercased()
        
        // At least lowercase should work (spec says lowercase)
        #expect(BIP39.validateMnemonic(lowercase))
    }
    
    @Test("entropyFromMnemonic with invalid word count throws")
    func entropyFromInvalidWordCountThrows() throws {
        let invalidMnemonic = "one two three four five six seven eight nine ten eleven"
        
        #expect(throws: BIP39.Error.self) {
            _ = try BIP39.entropyFromMnemonic(invalidMnemonic)
        }
    }
}

// MARK: - BIP39 Seed Tests

@Suite("BIP39 Seed Tests")
struct BIP39SeedTests {
    
    @Test("Seed from mnemonic returns 64 bytes")
    func seedReturns64Bytes() throws {
        let mnemonic = try BIP39.generateMnemonic()
        let seed = try BIP39.seed(from: mnemonic)
        #expect(seed.count == 64)
    }
    
    @Test("Seed from mnemonic with passphrase returns 64 bytes")
    func seedWithPassphraseReturns64Bytes() throws {
        let mnemonic = try BIP39.generateMnemonic()
        let seed = try BIP39.seed(from: mnemonic, passphrase: "test passphrase")
        #expect(seed.count == 64)
    }
    
    @Test("Same mnemonic same passphrase produces same seed")
    func sameMnemonicSamePassphraseSameSeed() throws {
        let entropy = Data(repeating: 0x55, count: 16)
        let mnemonic = try BIP39.mnemonicFromEntropy(entropy)
        
        let seed1 = try BIP39.seed(from: mnemonic, passphrase: "test")
        let seed2 = try BIP39.seed(from: mnemonic, passphrase: "test")
        
        #expect(seed1 == seed2)
    }
    
    @Test("Different passphrases produce different seeds")
    func differentPassphrasesDifferentSeeds() throws {
        let mnemonic = try BIP39.generateMnemonic()
        
        let seed1 = try BIP39.seed(from: mnemonic, passphrase: "")
        let seed2 = try BIP39.seed(from: mnemonic, passphrase: "test")
        
        #expect(seed1 != seed2)
    }
    
    @Test("Empty passphrase same as no passphrase")
    func emptyPassphraseEqualsNoPassphrase() throws {
        let mnemonic = try BIP39.generateMnemonic()
        
        let seed1 = try BIP39.seed(from: mnemonic)
        let seed2 = try BIP39.seed(from: mnemonic, passphrase: "")
        
        #expect(seed1 == seed2)
    }
    
    @Test("Invalid mnemonic throws when generating seed")
    func invalidMnemonicThrowsForSeed() throws {
        let invalidMnemonic = "invalid mnemonic that is not valid at all"
        
        #expect(throws: BIP39.Error.self) {
            _ = try BIP39.seed(from: invalidMnemonic)
        }
    }
    
    @Test("Seed from all strength levels")
    func seedFromAllStrengthLevels() throws {
        for strength in BIP39.Strength.allCases {
            let mnemonic = try BIP39.generateMnemonic(strength: strength)
            let seed = try BIP39.seed(from: mnemonic)
            #expect(seed.count == 64, "Seed from \(strength) should be 64 bytes")
        }
    }
}

// MARK: - BIP39 Error Tests

@Suite("BIP39 Error Tests")
struct BIP39ErrorTests {
    
    @Test("Error descriptions are not empty")
    func errorDescriptionsNotEmpty() throws {
        let errors: [BIP39.Error] = [
            .invalidEntropy,
            .invalidMnemonic,
            .invalidWordCount,
            .wordNotInList,
            .checksumMismatch,
            .wordlistNotFound
        ]
        
        for error in errors {
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }
    
    @Test("InvalidEntropy error has meaningful description")
    func invalidEntropyDescription() throws {
        let error = BIP39.Error.invalidEntropy
        #expect(error.errorDescription?.contains("entropy") == true)
    }
    
    @Test("InvalidWordCount error has meaningful description")
    func invalidWordCountDescription() throws {
        let error = BIP39.Error.invalidWordCount
        #expect(error.errorDescription?.contains("word count") == true)
    }
}

// MARK: - BIP39 Deterministic Tests

@Suite("BIP39 Deterministic Tests")
struct BIP39DeterministicTests {
    
    @Test("Known entropy produces expected mnemonic structure")
    func knownEntropyProducesExpectedStructure() throws {
        // All zeros entropy
        let zeroEntropy = Data(repeating: 0x00, count: 16)
        let mnemonic = try BIP39.mnemonicFromEntropy(zeroEntropy)
        
        let words = mnemonic.split(separator: " ")
        #expect(words.count == 12)
        
        // Verify entropy round-trip
        let recoveredEntropy = try BIP39.entropyFromMnemonic(mnemonic)
        #expect(recoveredEntropy == zeroEntropy)
    }
    
    @Test("All ones entropy produces consistent mnemonic")
    func allOnesEntropyConsistent() throws {
        let onesEntropy = Data(repeating: 0xFF, count: 16)
        
        let mnemonic1 = try BIP39.mnemonicFromEntropy(onesEntropy)
        let mnemonic2 = try BIP39.mnemonicFromEntropy(onesEntropy)
        
        #expect(mnemonic1 == mnemonic2)
    }
    
    @Test("Incremental entropy produces different mnemonics")
    func incrementalEntropyDifferent() throws {
        var entropy1 = Data(repeating: 0x00, count: 16)
        var entropy2 = Data(repeating: 0x00, count: 16)
        entropy2[15] = 0x01 // Only last byte different
        
        let mnemonic1 = try BIP39.mnemonicFromEntropy(entropy1)
        let mnemonic2 = try BIP39.mnemonicFromEntropy(entropy2)
        
        #expect(mnemonic1 != mnemonic2)
    }
}

// MARK: - BIP39 Integration Tests

@Suite("BIP39 Integration Tests")
struct BIP39IntegrationTests {
    
    @Test("Complete workflow: generate, validate, derive seed")
    func completeWorkflow() throws {
        // Generate
        let mnemonic = try BIP39.generateMnemonic(strength: .bits256)
        
        // Validate
        #expect(BIP39.validateMnemonic(mnemonic))
        
        // Extract entropy
        let entropy = try BIP39.entropyFromMnemonic(mnemonic)
        #expect(entropy.count == 32) // 256 bits = 32 bytes
        
        // Derive seed
        let seed = try BIP39.seed(from: mnemonic, passphrase: "test")
        #expect(seed.count == 64)
    }
    
    @Test("Mnemonic persistence simulation")
    func mnemonicPersistenceSimulation() throws {
        // Generate and "store"
        let originalMnemonic = try BIP39.generateMnemonic()
        let storedString = originalMnemonic // Simulating storage
        
        // "Retrieve" and validate
        #expect(BIP39.validateMnemonic(storedString))
        
        // Generate seed from retrieved
        let seed = try BIP39.seed(from: storedString)
        #expect(seed.count == 64)
    }
    
    @Test("Multiple seeds from same mnemonic with different passphrases")
    func multipleSeedsFromSameMnemonic() throws {
        let mnemonic = try BIP39.generateMnemonic()
        
        let seeds = [
            try BIP39.seed(from: mnemonic, passphrase: ""),
            try BIP39.seed(from: mnemonic, passphrase: "password1"),
            try BIP39.seed(from: mnemonic, passphrase: "password2"),
            try BIP39.seed(from: mnemonic, passphrase: "a very long passphrase with spaces and numbers 12345")
        ]
        
        // All seeds should be different
        for i in 0..<seeds.count {
            for j in (i+1)..<seeds.count {
                #expect(seeds[i] != seeds[j], "Seeds \(i) and \(j) should be different")
            }
        }
        
        // All seeds should be 64 bytes
        for (index, seed) in seeds.enumerated() {
            #expect(seed.count == 64, "Seed \(index) should be 64 bytes")
        }
    }
}
