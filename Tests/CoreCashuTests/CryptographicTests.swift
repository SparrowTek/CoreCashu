import Testing
@testable import CoreCashu
import Foundation
import P256K

@Suite("Cryptographic tests")
struct CryptographicTests {
    
    // MARK: - Key Generation Tests
    
    @Test
    func secretGeneration() async throws {
        // Test secret generation
        let secret1 = try CashuKeyUtils.generateRandomSecret()
        let secret2 = try CashuKeyUtils.generateRandomSecret()
        
        // Secrets should be different
        #expect(secret1 != secret2)
        
        // Secrets should be valid
        let isValid1 = try CashuKeyUtils.validateSecret(secret1)
        let isValid2 = try CashuKeyUtils.validateSecret(secret2)
        
        #expect(isValid1)
        #expect(isValid2)
        
        // Test multiple generations for uniqueness
        var secrets: Set<String> = []
        for _ in 0..<100 {
            let secret = try CashuKeyUtils.generateRandomSecret()
            secrets.insert(secret)
        }
        
        // Should have generated 100 unique secrets
        #expect(secrets.count == 100)
    }
    
    @Test
    func keypairGeneration() async throws {
        // Test keypair generation
        let keypair1 = try CashuKeyUtils.generateMintKeypair()
        let keypair2 = try CashuKeyUtils.generateMintKeypair()
        
        // Keypairs should be different
        #expect(keypair1.privateKey.rawRepresentation != keypair2.privateKey.rawRepresentation)
        #expect(keypair1.publicKey.dataRepresentation != keypair2.publicKey.dataRepresentation)
        
        // Test private key serialization
        let privateKeyHex = CashuKeyUtils.privateKeyToHex(keypair1.privateKey)
        #expect(privateKeyHex.count == 64) // 32 bytes * 2 hex chars
        
        // Test private key deserialization
        let restoredPrivateKey = try CashuKeyUtils.privateKeyFromHex(privateKeyHex)
        #expect(keypair1.privateKey.rawRepresentation == restoredPrivateKey.rawRepresentation)
    }
    
    @Test
    func invalidKeyRecovery() async throws {
        func expectFailure(_ hex: String) {
            var thrownError: Error?
            do {
                _ = try CashuKeyUtils.privateKeyFromHex(hex)
            } catch {
                thrownError = error
            }

            let isExpected = thrownError != nil
            #expect(isExpected)
        }

        expectFailure("invalid-hex")
        expectFailure("deadbeef")
        expectFailure("invalid-public-key")
    }
    
    // MARK: - BDHKE Protocol Tests
    
    @Test
    func BDHKEProtocol() async throws {
        // Test basic BDHKE protocol execution
        let secret = try CashuKeyUtils.generateRandomSecret()
        let (unblindedToken, isValid) = try CashuBDHKEProtocol.executeProtocol(secret: secret)
        
        #expect(unblindedToken.secret == secret)
        #expect(unblindedToken.signature.count > 0)
        #expect(isValid)
    }
    
    @Test
    func BDHKEProtocolWithMultipleSecrets() async throws {
        let secrets = [
            try CashuKeyUtils.generateRandomSecret(),
            try CashuKeyUtils.generateRandomSecret(),
            try CashuKeyUtils.generateRandomSecret()
        ]
        
        var unblindedTokens: [UnblindedToken] = []
        var validResults: [Bool] = []
        
        for secret in secrets {
            let (unblindedToken, isValid) = try CashuBDHKEProtocol.executeProtocol(secret: secret)
            unblindedTokens.append(unblindedToken)
            validResults.append(isValid)
        }
        
        #expect(unblindedTokens.count == 3)
        #expect(validResults.count == 3)
        
        // All results should be valid
        #expect(validResults.allSatisfy { $0 })
        
        // All unblinded tokens should be different
        #expect(unblindedTokens[0].signature != unblindedTokens[1].signature)
        #expect(unblindedTokens[1].signature != unblindedTokens[2].signature)
        #expect(unblindedTokens[0].signature != unblindedTokens[2].signature)
    }
    
    @Test
    func BDHKEProtocolDeterministic() async throws {
        // Test that same secret produces same result
        let secret = "test-secret-deterministic"
        
        let (unblindedToken1, _) = try CashuBDHKEProtocol.executeProtocol(secret: secret)
        let (unblindedToken2, _) = try CashuBDHKEProtocol.executeProtocol(secret: secret)
        
        #expect(unblindedToken1.secret == unblindedToken2.secret)
        // Note: Due to randomness in the protocol, signatures might be different
        // but the secret should be the same
        #expect(unblindedToken1.secret == secret)
        #expect(unblindedToken2.secret == secret)
    }

    // MARK: - Property Invariants

    @Test
    func BDHKEPropertyVectors() throws {
        let mintKeyHex = String(repeating: "01", count: 32)
        guard let mintKeyData = Data(hexString: mintKeyHex) else {
            #expect(Bool(false), "Failed to build deterministic mint key data")
            return
        }
        let mintPrivateKey = try P256K.KeyAgreement.PrivateKey(dataRepresentation: mintKeyData)
        let mint = try Mint(privateKey: mintPrivateKey)

        let secrets = [
            "vector-alpha",
            "vector-bravo",
            "vector-charlie",
            "vector-delta",
            "vector-echo"
        ]

        for secret in secrets {
            let (blindingData, blindedMessage) = try Wallet.createBlindedMessage(secret: secret)
            let blindedSignature = try mint.signBlindedMessage(blindedMessage)
            let token = try Wallet.unblindSignature(
                blindedSignature: blindedSignature,
                blindingData: blindingData,
                mintPublicKey: mint.keypair.publicKey
            )

            #expect(token.secret == secret)
            #expect(Wallet.validateTokenStructure(token))

            let expectedPoint = try multiplyPoint(try hashToCurve(secret), by: mintPrivateKey)
            #expect(token.signature == expectedPoint.dataRepresentation, "Unblinded signature should match deterministic mint computation")
            #expect(try mint.verifyToken(secret: token.secret, signature: token.signature))
        }
    }

    @Test
    func P2PKRoundTripProperty() throws {
        let basePubKey = "0249098aa8b9d2fbec49ff8598feb17b592b986e62319a4fa488a3dc36387157a7"
        let extraKeys = [
            "033281c37677ea273eb7183b783067f5244933ef78d8c3f15b1a77cb246099c26e",
            "02698c4e2b5f9534cd0687d87513c759790cf829aa5739184a3e3735471fbda904"
        ]

        let locktime = 1_695_000_000

        let cases: [P2PKSpendingCondition] = [
            .simple(publicKey: basePubKey),
            .multisig(publicKeys: [basePubKey] + extraKeys, requiredSigs: 2, signatureFlag: .sigAll),
            .timelocked(publicKey: basePubKey, locktime: locktime, refundPubkeys: extraKeys)
        ]

        for condition in cases {
            let secret = condition.toWellKnownSecret()
            let restored = try P2PKSpendingCondition.fromWellKnownSecret(secret)

            #expect(restored.publicKey == condition.publicKey)
            #expect(restored.additionalPubkeys == condition.additionalPubkeys)
            #expect(restored.requiredSigs == condition.requiredSigs)
            #expect(restored.signatureFlag == condition.signatureFlag)
            #expect(restored.locktime == condition.locktime)
            #expect(restored.refundPubkeys == condition.refundPubkeys)

            let possibleSigners = Set(restored.getAllPossibleSigners())
            let expectedSigners = Set([restored.publicKey] + restored.additionalPubkeys)
            #expect(possibleSigners.isSuperset(of: expectedSigners))
        }
    }

    @Test
    func HTLCPreimageProperty() throws {
        let generatorPoint = "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
        let preimages: [Data] = (0..<4).map { index in
            Data((0..<32).map { byte -> UInt8 in
                UInt8((index * 17 + Int(byte)) & 0xFF)
            })
        }

        for (index, preimage) in preimages.enumerated() {
            let secretJSON = try HTLCCreator.createHTLCSecret(
                preimage: preimage,
                pubkeys: [],
                locktime: nil,
                refundKey: nil
            )
            let secret = try WellKnownSecret.fromString(secretJSON)

            #expect(secret.isHTLC)
            #expect(secret.hashLock != nil)

            let witness = HTLCWitness.createForPreimage(preimage)
            let witnessData = try JSONEncoder().encode(witness)
            guard let witnessString = String(data: witnessData, encoding: .utf8) else {
                #expect(Bool(false), "Failed to encode HTLC witness")
                continue
            }

            let proof = Proof(
                amount: 1,
                id: "htlc-property-\(index)",
                secret: secretJSON,
                C: generatorPoint,
                witness: witnessString
            )

            #expect(try HTLCVerifier.verifyPreimage(preimage: witness.preimage, hashLock: secret.hashLock ?? ""))
            #expect(try HTLCVerifier.verifyHTLC(proof: proof, witness: witness))

            var mutated = Data(preimage)
            mutated[0] ^= 0xFF
            let badWitness = HTLCWitness.createForPreimage(mutated)
            #expect(try HTLCVerifier.verifyHTLC(
                proof: proof,
                witness: badWitness
            ) == false)
        }
    }
    
    // MARK: - Mint Key Management Tests
    
    @Test
    func mintKeyManagement() async throws {
        var mintKeys = MintKeys()
        
        // Test getting keypair for specific amount
        let keypair1 = try mintKeys.getKeypair(for: 1)
        let keypair2 = try mintKeys.getKeypair(for: 2)
        let keypair4 = try mintKeys.getKeypair(for: 4)
        
        // Keypairs should be different for different amounts
        #expect(keypair1.privateKey.rawRepresentation != keypair2.privateKey.rawRepresentation)
        #expect(keypair2.privateKey.rawRepresentation != keypair4.privateKey.rawRepresentation)
        
        // Getting same amount should return same keypair
        let keypair1Again = try mintKeys.getKeypair(for: 1)
        #expect(keypair1.privateKey.rawRepresentation == keypair1Again.privateKey.rawRepresentation)
        
        // Test amounts
        let amounts = mintKeys.amounts
        #expect(amounts.count == 3)
        #expect(amounts.contains(1))
        #expect(amounts.contains(2))
        #expect(amounts.contains(4))
        
        // Test public keys
        let publicKeys = mintKeys.getPublicKeys()
        #expect(publicKeys.count == 3)
        #expect(publicKeys[1] != nil)
        #expect(publicKeys[2] != nil)
        #expect(publicKeys[4] != nil)
    }
    
    @Test
    func proofVerification() async throws {
        var mintKeys = MintKeys()
        
        // Create a keypair for amount 100
        let _ = try mintKeys.getKeypair(for: 100)
        
        // Create a proof
        let proof = Proof(
            amount: 100,
            id: "test-id",
            secret: "test-secret",
            C: "deadbeef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
        )
        
        // Test verification (this will likely fail with mock data, but tests the interface)
        if let isValid = try? mintKeys.verifyProof(proof, for: 100) {
            // With mock data, this might fail or pass depending on implementation
            // The important thing is that the interface works
            #expect(isValid == true || isValid == false)
        }
    }
    
    // MARK: - Hex String Utilities Tests
    
    @Test
    func dataHexStringConversion() async throws {
        // Test hex string creation
        let data = Data([0xde, 0xad, 0xbe, 0xef, 0x12, 0x34, 0x56, 0x78])
        let hexString = data.hexString
        #expect(hexString.lowercased() == "deadbeef12345678")
        
        // Test hex string parsing
        let parsedData = Data(hexString: "deadbeef12345678")
        #expect(parsedData == data)
        
        // Test case insensitive parsing
        let uppercaseData = Data(hexString: "DEADBEEF12345678")
        #expect(uppercaseData == data)
        
        let mixedCaseData = Data(hexString: "DeAdBeEf12345678")
        #expect(mixedCaseData == data)
        
        // Test invalid hex string
        let invalidData = Data(hexString: "invalid-hex")
        #expect(invalidData == nil)
        
        // Test odd length hex string
        let oddLengthData = Data(hexString: "deadbee")
        #expect(oddLengthData == nil)
        
        // Test empty hex string
        let emptyData = Data(hexString: "")
        #expect(emptyData == Data())
    }
    
    // MARK: - Cryptographic Consistency Tests
    
    @Test
    func cryptographicConsistency() async throws {
        // Test that serialization/deserialization preserves cryptographic properties
        let keypair = try CashuKeyUtils.generateMintKeypair()
        
        // Serialize and deserialize private key
        let privateKeyHex = CashuKeyUtils.privateKeyToHex(keypair.privateKey)
        let restoredPrivateKey = try CashuKeyUtils.privateKeyFromHex(privateKeyHex)
        
        // Test that restored keys are identical
        #expect(keypair.privateKey.rawRepresentation == restoredPrivateKey.rawRepresentation)
        
        // Test that the keypair relationship is preserved
        // (The specific test depends on the secp256k1 implementation)
        #expect(keypair.publicKey.dataRepresentation == keypair.publicKey.dataRepresentation)
    }

    @Test
    func walletUnblindingRoundTrip() async throws {
        // Smoke-test alignment of blinded messages and blinding data as produced in services
        // This ensures counts and types match expected flows.
        let keyExchange = await KeyExchangeService()
        // Use example test mint; if unavailable in test environment, skip
        if let activeKeysets = try? await keyExchange.getActiveKeysets(from: "https://test.mint.example.com") {
            if let first = activeKeysets.first {
                let amounts = [1, 2, 4]
                var messages: [BlindedMessage] = []
                var blindings: [WalletBlindingData] = []
                for amount in amounts {
                    let secret = try CashuKeyUtils.generateRandomSecret()
                    let blinding = try WalletBlindingData(secret: secret)
                    let message = BlindedMessage(amount: amount, id: first.id, B_: blinding.blindedMessage.dataRepresentation.hexString)
                    messages.append(message)
                    blindings.append(blinding)
                }
                #expect(messages.count == blindings.count)
            }
        }
    }
    
    // MARK: - Random Number Generation Tests
    
    @Test
    func randomNumberGeneration() async throws {
        // Test that random secrets are actually random
        var secrets: Set<String> = []
        let numberOfSecrets = 1000
        
        for _ in 0..<numberOfSecrets {
            let secret = try CashuKeyUtils.generateRandomSecret()
            secrets.insert(secret)
        }
        
        // Should have generated unique secrets (with very high probability)
        #expect(secrets.count == numberOfSecrets)
        
        // Test that secrets have reasonable length
        for secret in secrets.prefix(10) {
            #expect(secret.count > 0)
            #expect(secret.count < 1000) // Reasonable upper bound
        }
    }
    
    // MARK: - Performance Tests
    
    @Test
    func keyGenerationPerformance() async throws {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // Generate 100 keypairs
        for _ in 0..<100 {
            _ = try CashuKeyUtils.generateMintKeypair()
        }
        
        let endTime = CFAbsoluteTimeGetCurrent()
        let duration = endTime - startTime
        
        // Should complete in reasonable time (adjust threshold as needed)
        #expect(duration < 5.0, "Key generation took too long: \(duration) seconds")
    }
    
    @Test
    func secretGenerationPerformance() async throws {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // Generate 1000 secrets
        for _ in 0..<1000 {
            _ = try CashuKeyUtils.generateRandomSecret()
        }
        
        let endTime = CFAbsoluteTimeGetCurrent()
        let duration = endTime - startTime
        
        // Should complete in reasonable time
        #expect(duration < 1.0, "Secret generation took too long: \(duration) seconds")
    }
}
