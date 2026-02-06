//
//  NUT13Tests.swift
//  CashuKitTests
//
//  Tests for NUT-13: Deterministic Secrets
//

import Testing
@testable import CoreCashu
import Foundation
import P256K

@Suite("NUT-13 Tests", .serialized)
struct NUT13Tests {
    
    @Test("BIP39 mnemonic generation")
    func testMnemonicGeneration() throws {
        // Test 128-bit strength (12 words)
        let mnemonic12 = try CashuWallet.generateMnemonic(strength: 128)
        #expect(mnemonic12.split(separator: " ").count == 12)
        
        // Test 256-bit strength (24 words)
        let mnemonic24 = try CashuWallet.generateMnemonic(strength: 256)
        #expect(mnemonic24.split(separator: " ").count == 24)
        
        // Test invalid strength throws error
        #expect(throws: CashuError.self) {
            _ = try CashuWallet.generateMnemonic(strength: 123)
        }
    }
    
    @Test("BIP39 mnemonic validation")
    func testMnemonicValidation() {
        // Valid 12-word mnemonic with correct checksum
        let validMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        #expect(CashuWallet.validateMnemonic(validMnemonic) == true)
        
        // Invalid word count
        let invalidCount = "abandon ability able"
        #expect(CashuWallet.validateMnemonic(invalidCount) == false)
        
        // Invalid word
        let invalidWord = "abandon ability able about above absent absorb abstract absurd abuse access invalid"
        #expect(CashuWallet.validateMnemonic(invalidWord) == false)
    }

    @Test("Deterministic mnemonic generation via entropy override")
    func testDeterministicMnemonicGeneration() throws {
        let mnemonic = try SecureRandom.withGenerator({ count in
            Data(repeating: 0x00, count: count)
        }) {
            try CashuWallet.generateMnemonic(strength: 128)
        }

        let expected = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        #expect(mnemonic == expected)
    }
    
    @Test("Keyset ID to integer conversion")
    func testKeysetIDToInt() throws {
        let derivation = DeterministicSecretDerivation(masterKey: Data(repeating: 0, count: 64))
        
        // Test case from spec
        let keysetID = "009a1f293253e41e"
        let keysetInt = try derivation.keysetIDToInt(keysetID)
        
        // The expected value would be calculated as:
        // int.from_bytes(bytes.fromhex("009a1f293253e41e"), "big") % (2**31 - 1)
        #expect(keysetInt > 0)
        #expect(keysetInt < NUT13Constants.maxKeysetInt)
    }
    
    @Test("Deterministic secret derivation")
    func testSecretDerivation() async throws {
        // Test vector mnemonic
        let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let derivation = try DeterministicSecretDerivation(mnemonic: testMnemonic)
        
        let keysetID = "009a1f293253e41e"
        let counter: UInt32 = 0
        
        let secret = try derivation.deriveSecret(keysetID: keysetID, counter: counter)
        #expect(!secret.isEmpty)
        #expect(secret.count == 64) // 32 bytes as hex
        
        let blindingFactor = try derivation.deriveBlindingFactor(keysetID: keysetID, counter: counter)
        #expect(blindingFactor.count == 32)
    }
    
    @Test("Counter management")
    func testCounterManagement() async {
        let manager = KeysetCounterManager()
        let keysetID = "test_keyset"
        
        // Initial counter should be 0
        let initial = await manager.getCounter(for: keysetID)
        #expect(initial == 0)
        
        // Increment counter
        await manager.incrementCounter(for: keysetID)
        let afterIncrement = await manager.getCounter(for: keysetID)
        #expect(afterIncrement == 1)
        
        // Set specific value
        await manager.setCounter(for: keysetID, value: 10)
        let afterSet = await manager.getCounter(for: keysetID)
        #expect(afterSet == 10)
        
        // Reset counter
        await manager.resetCounter(for: keysetID)
        let afterReset = await manager.getCounter(for: keysetID)
        #expect(afterReset == 0)
        
        // Multiple keysets
        let keysetID2 = "another_keyset"
        await manager.setCounter(for: keysetID2, value: 5)
        let counters = await manager.getAllCounters()
        #expect(counters[keysetID] == 0)
        #expect(counters[keysetID2] == 5)
    }
    
    @Test("Wallet restoration batch generation")
    func testRestorationBatchGeneration() async throws {
        let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let derivation = try DeterministicSecretDerivation(mnemonic: testMnemonic)
        let counterManager = KeysetCounterManager()
        
        let restoration = WalletRestoration(
            derivation: derivation,
            counterManager: counterManager
        )
        
        let keysetID = "009a1f293253e41e"
        let startCounter: UInt32 = 0
        let batchSize = 10
        
        let batch = try await restoration.generateBlindedMessages(
            keysetID: keysetID,
            startCounter: startCounter,
            batchSize: batchSize
        )
        
        #expect(batch.count == batchSize)
        
        // Check that all blinded messages have valid B_ values
        for (blindedMessage, _) in batch {
            #expect(!blindedMessage.B_.isEmpty)
            #expect(blindedMessage.id == keysetID)
        }
    }

    @Test("Wallet restoration from secure store")
    func testRestoreFromSecureStore() async throws {
        let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let secureStore = try await FileSecureStore(directory: temporaryDirectory())
        try await secureStore.saveMnemonic(mnemonic)
        
        let configuration = WalletConfiguration(mintURL: "https://test.mint.example.com")
        let wallet = try await CashuWallet.restoreFromSecureStore(
            configuration: configuration,
            secureStore: secureStore
        )
        
        #expect(await wallet.state == .uninitialized)
        let loaded = try await secureStore.loadMnemonic()
        #expect(loaded == mnemonic)
    }

    private func temporaryDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("cashu-secure-store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    
    @Test("Mnemonic validation in wallet")
    func testWalletMnemonicValidation() {
        let validMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        #expect(CashuWallet.validateMnemonic(validMnemonic) == true)
        
        let invalidMnemonic = "invalid mnemonic phrase"
        #expect(CashuWallet.validateMnemonic(invalidMnemonic) == false)
    }
    
    @Test("Deterministic path derivation")
    func testDeterministicPaths() throws {
        let derivation = DeterministicSecretDerivation(masterKey: Data(repeating: 0, count: 64))
        
        let keysetID = "009a1f293253e41e"
        let counter: UInt32 = 5
        
        // Derive secret and blinding factor with same counter
        let secret1 = try derivation.deriveSecret(keysetID: keysetID, counter: counter)
        let secret2 = try derivation.deriveSecret(keysetID: keysetID, counter: counter)
        
        // Should be deterministic (same output for same input)
        #expect(secret1 == secret2)
        
        // Different counters should produce different secrets
        let secret3 = try derivation.deriveSecret(keysetID: keysetID, counter: counter + 1)
        #expect(secret1 != secret3)
        
        // Different keysets should produce different secrets
        let keysetID2 = "00ad268c4d1f5826"
        let secret4 = try derivation.deriveSecret(keysetID: keysetID2, counter: counter)
        #expect(secret1 != secret4)
    }
    
    @Test("Proof restoration from blinded signatures")
    func testProofRestoration() async throws {
        let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let derivation = try DeterministicSecretDerivation(mnemonic: testMnemonic)
        let counterManager = KeysetCounterManager()
        
        let restoration = WalletRestoration(
            derivation: derivation,
            counterManager: counterManager
        )
        
        let keysetID = "009a1f293253e41e"
        
        // Mock blinded signatures (in real scenario, these come from mint)
        let blindedSignatures = [
            BlindSignature(amount: 1, id: keysetID, C_: "02a9acc1e48c25eeeb9289b5031cc57da9fe72f3fe2861d264bdc074209b107ba2"),
            BlindSignature(amount: 2, id: keysetID, C_: "02a9acc1e48c25eeeb9289b5031cc57da9fe72f3fe2861d264bdc074209b107ba2")
        ]
        
        // Generate corresponding secrets and blinding factors
        var secrets: [String] = []
        var blindingFactors: [Data] = []
        
        for i in 0..<blindedSignatures.count {
            let secret = try derivation.deriveSecret(keysetID: keysetID, counter: UInt32(i))
            let r = try derivation.deriveBlindingFactor(keysetID: keysetID, counter: UInt32(i))
            
            secrets.append(secret)
            blindingFactors.append(r)
        }
        
        // Create mock mint public key for testing
        let mockPrivateKey = try P256K.KeyAgreement.PrivateKey(dataRepresentation: Data(hexString: "0000000000000000000000000000000000000000000000000000000000000001")!)
        let mockPublicKey = mockPrivateKey.publicKey
        
        // Restore proofs
        let proofs = try restoration.restoreProofs(
            blindedSignatures: blindedSignatures,
            blindingFactors: blindingFactors,
            secrets: secrets,
            keysetID: keysetID,
            mintPublicKey: mockPublicKey
        )
        
        #expect(proofs.count == blindedSignatures.count)
        
        for (index, proof) in proofs.enumerated() {
            #expect(proof.amount == blindedSignatures[index].amount)
            #expect(proof.id == keysetID)
            #expect(proof.secret == secrets[index])
        }
    }
    
    // MARK: - NUT-13 Test Vectors
    
    @Test("Test vector: Keyset ID integer representation")
    func testVectorKeysetIDIntegerRepresentation() throws {
        // Test vector from NUT-13 specification
        let keysetID = "009a1f293253e41e"
        let expectedKeysetInt: UInt32 = 864559728
        
        let derivation = DeterministicSecretDerivation(masterKey: Data(repeating: 0, count: 64))
        let keysetInt = try derivation.keysetIDToInt(keysetID)
        
        #expect(keysetInt == expectedKeysetInt, "Keyset ID integer should match expected value from test vector")
        
        // Expected derivation path components for counter=0:
        // [129372 | 0x80000000, 0 | 0x80000000, 864559728 | 0x80000000, 0 | 0x80000000]
    }
    
    @Test("Test vector: Secret derivation")
    func testVectorSecretDerivation() throws {
        // Test vector from NUT-13 specification
        // https://github.com/cashubtc/nuts/blob/main/tests/13-tests.md
        let mnemonic = "half depart obvious quality work element tank gorilla view sugar picture humble"
        let derivation = try DeterministicSecretDerivation(mnemonic: mnemonic)
        let keysetID = "009a1f293253e41e"
        
        // Expected secrets for counters 0-4 (from official NUT-13 test vectors)
        let expectedSecrets = [
            "485875df74771877439ac06339e284c3acfcd9be7abf3bc20b516faeadfe77ae",
            "8f2b39e8e594a4056eb1e6dbb4b0c38ef13b1b2c751f64f810ec04ee35b77270",
            "bc628c79accd2364fd31511216a0fab62afd4a18ff77a20deded7b858c9860c8",
            "59284fd1650ea9fa17db2b3acf59ecd0f2d52ec3261dd4152785813ff27a33bf",
            "576c23393a8b31cc8da6688d9c9a96394ec74b40fdaf1f693a6bb84284334ea0"
        ]
        
        // Verify secrets match official test vectors
        for counter in 0..<5 {
            let secret = try derivation.deriveSecret(keysetID: keysetID, counter: UInt32(counter))
            #expect(secret == expectedSecrets[counter], "Secret for counter \(counter) should match NUT-13 test vector")
        }
        
        // Verify determinism (same inputs produce same outputs)
        let secret1 = try derivation.deriveSecret(keysetID: keysetID, counter: 0)
        let secret2 = try derivation.deriveSecret(keysetID: keysetID, counter: 0)
        #expect(secret1 == secret2, "Secret derivation should be deterministic")
    }
    
    @Test("Test vector: Blinding factor derivation")
    func testVectorBlindingFactorDerivation() throws {
        // Test vector from NUT-13 specification
        // https://github.com/cashubtc/nuts/blob/main/tests/13-tests.md
        let mnemonic = "half depart obvious quality work element tank gorilla view sugar picture humble"
        let derivation = try DeterministicSecretDerivation(mnemonic: mnemonic)
        let keysetID = "009a1f293253e41e"
        
        // Expected blinding factors (r values) for counters 0-4 (from official NUT-13 test vectors)
        let expectedBlindingFactors = [
            "ad00d431add9c673e843d4c2bf9a778a5f402b985b8da2d5550bf39cda41d679",
            "967d5232515e10b81ff226ecf5a9e2e2aff92d66ebc3edf0987eb56357fd6248",
            "b20f47bb6ae083659f3aa986bfa0435c55c6d93f687d51a01f26862d9b9a4899",
            "fb5fca398eb0b1deb955a2988b5ac77d32956155f1c002a373535211a2dfdc29",
            "5f09bfbfe27c439a597719321e061e2e40aad4a36768bb2bcc3de547c9644bf9"
        ]
        
        // Verify blinding factors match official test vectors
        for counter in 0..<5 {
            let r = try derivation.deriveBlindingFactor(keysetID: keysetID, counter: UInt32(counter))
            #expect(r.hexString == expectedBlindingFactors[counter], "Blinding factor for counter \(counter) should match NUT-13 test vector")
        }
        
        // Verify determinism (same inputs produce same outputs)
        let r1 = try derivation.deriveBlindingFactor(keysetID: keysetID, counter: 0)
        let r2 = try derivation.deriveBlindingFactor(keysetID: keysetID, counter: 0)
        #expect(r1 == r2, "Blinding factor derivation should be deterministic")
    }
    
    @Test("Test vector: Derivation paths")
    func testVectorDerivationPaths() throws {
        // Test vector from NUT-13 specification
        // https://github.com/cashubtc/nuts/blob/main/tests/13-tests.md
        let mnemonic = "half depart obvious quality work element tank gorilla view sugar picture humble"
        let derivation = try DeterministicSecretDerivation(mnemonic: mnemonic)
        let keysetID = "009a1f293253e41e"
        
        // The expected derivation paths are:
        // m/129372'/0'/864559728'/0'/0 (for secret at counter 0)
        // m/129372'/0'/864559728'/0'/1 (for blinding factor at counter 0)
        // etc.
        
        // Verify determinism - same path should always produce same secret
        let firstSecret = try derivation.deriveSecret(keysetID: keysetID, counter: 0)
        let firstSecretAgain = try derivation.deriveSecret(keysetID: keysetID, counter: 0)
        #expect(firstSecret == firstSecretAgain, "Derivation should be deterministic")
        
        // Verify different counters produce different secrets
        let secondSecret = try derivation.deriveSecret(keysetID: keysetID, counter: 1)
        #expect(firstSecret != secondSecret, "Different counters should produce different secrets")
        
        // Verify different keysets produce different secrets
        let differentKeysetID = "00ad268c4d1f5826"
        let differentKeysetSecret = try derivation.deriveSecret(keysetID: differentKeysetID, counter: 0)
        #expect(firstSecret != differentKeysetSecret, "Different keyset IDs should produce different secrets")
        
        // Verify secret and blinding factor at same counter are different
        let blindingFactor = try derivation.deriveBlindingFactor(keysetID: keysetID, counter: 0)
        #expect(firstSecret != blindingFactor.hexString, "Secret and blinding factor at same counter should differ")
    }
    
    // MARK: - BIP32 Compliance Tests
    
    @Test("BIP32 master key derivation from seed")
    func testBIP32MasterKeyDerivation() throws {
        // The BIP32 spec says master key is created using HMAC-SHA512 with key "Bitcoin seed"
        // and the seed as data. The left 32 bytes are the private key, right 32 bytes are chain code.
        let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        
        // Verify derivation produces consistent results
        let derivation1 = try DeterministicSecretDerivation(mnemonic: mnemonic)
        let derivation2 = try DeterministicSecretDerivation(mnemonic: mnemonic)
        
        let secret1 = try derivation1.deriveSecret(keysetID: "009a1f293253e41e", counter: 0)
        let secret2 = try derivation2.deriveSecret(keysetID: "009a1f293253e41e", counter: 0)
        
        #expect(secret1 == secret2, "Same mnemonic should produce same derived secrets")
    }
    
    @Test("BIP32 hardened child key derivation")
    func testBIP32HardenedDerivation() throws {
        // All path components in NUT-13 except the last one are hardened (index >= 0x80000000)
        // This test verifies hardened derivation works correctly
        let mnemonic = "half depart obvious quality work element tank gorilla view sugar picture humble"
        let derivation = try DeterministicSecretDerivation(mnemonic: mnemonic)
        
        // Test with multiple counters to verify hardened derivation
        var secrets: [String] = []
        for counter: UInt32 in 0..<10 {
            let secret = try derivation.deriveSecret(keysetID: "009a1f293253e41e", counter: counter)
            #expect(!secrets.contains(secret), "Each counter should produce unique secret")
            secrets.append(secret)
        }
        
        #expect(secrets.count == 10, "Should have 10 unique secrets")
    }
    
    @Test("BIP39 seed generation with passphrase")
    func testBIP39SeedWithPassphrase() throws {
        let mnemonic = "half depart obvious quality work element tank gorilla view sugar picture humble"
        
        // Without passphrase
        let derivation1 = try DeterministicSecretDerivation(mnemonic: mnemonic, passphrase: "")
        let secret1 = try derivation1.deriveSecret(keysetID: "009a1f293253e41e", counter: 0)
        
        // With passphrase
        let derivation2 = try DeterministicSecretDerivation(mnemonic: mnemonic, passphrase: "my secret passphrase")
        let secret2 = try derivation2.deriveSecret(keysetID: "009a1f293253e41e", counter: 0)
        
        // Same mnemonic with different passphrases should produce different secrets
        #expect(secret1 != secret2, "Different passphrases should produce different secrets")
        
        // Same mnemonic + passphrase should be deterministic
        let derivation3 = try DeterministicSecretDerivation(mnemonic: mnemonic, passphrase: "my secret passphrase")
        let secret3 = try derivation3.deriveSecret(keysetID: "009a1f293253e41e", counter: 0)
        #expect(secret2 == secret3, "Same mnemonic + passphrase should produce same secret")
    }
    
    @Test("Keyset ID to integer edge cases")
    func testKeysetIDToIntEdgeCases() throws {
        let derivation = DeterministicSecretDerivation(masterKey: Data(repeating: 0, count: 64))
        
        // Test the official test vector keyset ID
        let keysetID = "009a1f293253e41e"
        let keysetInt = try derivation.keysetIDToInt(keysetID)
        #expect(keysetInt == 864559728, "Keyset ID should convert to 864559728 per NUT-13 spec")
        
        // Test all zeros keyset ID
        let zeroKeysetInt = try derivation.keysetIDToInt("0000000000000000")
        #expect(zeroKeysetInt == 0, "All-zero keyset ID should convert to 0")
        
        // Verify result is always less than 2^31 - 1 (max keyset int)
        let maxKeysetInt: UInt32 = UInt32(1 << 31) - 1
        #expect(keysetInt < maxKeysetInt, "Keyset int should be less than 2^31 - 1")
        
        // Test invalid keyset ID (wrong length)
        #expect(throws: CashuError.self) {
            _ = try derivation.keysetIDToInt("009a1f29")  // Too short (4 bytes instead of 8)
        }
        
        #expect(throws: CashuError.self) {
            _ = try derivation.keysetIDToInt("009a1f293253e41e00")  // Too long (9 bytes instead of 8)
        }
        
        // Test invalid hex string
        #expect(throws: CashuError.self) {
            _ = try derivation.keysetIDToInt("gggggggggggggggg")  // Invalid hex chars
        }
    }
    
    @Test("Large counter values")
    func testLargeCounterValues() throws {
        let mnemonic = "half depart obvious quality work element tank gorilla view sugar picture humble"
        let derivation = try DeterministicSecretDerivation(mnemonic: mnemonic)
        let keysetID = "009a1f293253e41e"
        
        // Test with large counter values
        let largeCounters: [UInt32] = [1000, 10000, 100000, UInt32.max - 1]
        
        for counter in largeCounters {
            let secret = try derivation.deriveSecret(keysetID: keysetID, counter: counter)
            #expect(secret.count == 64, "Secret should be 32 bytes (64 hex chars) for counter \(counter)")
            
            let r = try derivation.deriveBlindingFactor(keysetID: keysetID, counter: counter)
            #expect(r.count == 32, "Blinding factor should be 32 bytes for counter \(counter)")
        }
    }
}
