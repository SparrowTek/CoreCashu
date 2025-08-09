//
//  NUT12Tests.swift
//  CashuKitTests
//
//  Tests for NUT-12: Offline ecash signature validation
//

import Testing
import Foundation
@testable import CoreCashu
@preconcurrency import P256K

struct NUT12Tests {
    
    @Test("DLEQ proof generation and verification")
    func testDLEQProofGeneration() async throws {
        // Setup: Create a mint with a keypair
        let mint = try Mint()
        let mintPrivateKey = mint.keypair.privateKey
        let mintPublicKey = mint.keypair.publicKey
        
        // Create a wallet blinding data
        let secret = "test_secret_12345"
        let blindingData = try WalletBlindingData(secret: secret)
        
        // Mint signs the blinded message
        let blindedSignatureData = try mint.signBlindedMessage(blindingData.blindedMessage.dataRepresentation)
        let blindedSignature = try P256K.KeyAgreement.PublicKey(dataRepresentation: blindedSignatureData, format: .compressed)
        
        // Generate DLEQ proof
        let dleqProof = try generateDLEQProof(
            privateKey: mintPrivateKey,
            blindedMessage: blindingData.blindedMessage,
            blindedSignature: blindedSignature
        )
        
        // Verify the DLEQ proof (Alice's perspective)
        let isValid = try verifyDLEQProofAlice(
            proof: dleqProof,
            mintPublicKey: mintPublicKey,
            blindedMessage: blindingData.blindedMessage,
            blindedSignature: blindedSignature
        )
        
        #expect(isValid)
    }
    
    @Test("DLEQ proof verification by Carol")
    func testDLEQProofVerificationByCarol() async throws {
        // Setup: Create a mint with a keypair
        let mint = try Mint()
        let mintPrivateKey = mint.keypair.privateKey
        let mintPublicKey = mint.keypair.publicKey
        
        // Alice creates a blinded message
        let secret = "test_secret_carol"
        let blindingData = try WalletBlindingData(secret: secret)
        
        // Mint signs the blinded message
        let blindedSignatureData = try mint.signBlindedMessage(blindingData.blindedMessage.dataRepresentation)
        let blindedSignature = try P256K.KeyAgreement.PublicKey(dataRepresentation: blindedSignatureData, format: .compressed)
        
        // Generate DLEQ proof
        let dleqProof = try generateDLEQProof(
            privateKey: mintPrivateKey,
            blindedMessage: blindingData.blindedMessage,
            blindedSignature: blindedSignature
        )
        
        // Alice unblinds the signature
        let unblindedToken = try Wallet.unblindSignature(
            blindedSignature: blindedSignatureData,
            blindingData: blindingData,
            mintPublicKey: mintPublicKey
        )
        
        // Create DLEQ proof with blinding factor for Carol
        let dleqProofWithR = DLEQProof(
            e: dleqProof.e,
            s: dleqProof.s,
            r: blindingData.blindingFactor.rawRepresentation.hexString
        )
        
        // Carol verifies the DLEQ proof
        let signaturePoint = try P256K.KeyAgreement.PublicKey(dataRepresentation: unblindedToken.signature, format: .compressed)
        let isValid = try verifyDLEQProofCarol(
            proof: dleqProofWithR,
            mintPublicKey: mintPublicKey,
            secret: secret,
            signature: signaturePoint
        )
        
        #expect(isValid)
    }
    
    @Test("DLEQ hash function")
    func testDLEQHashFunction() async throws {
        // Create test public keys
        let key1 = try P256K.KeyAgreement.PrivateKey().publicKey
        let key2 = try P256K.KeyAgreement.PrivateKey().publicKey
        let key3 = try P256K.KeyAgreement.PrivateKey().publicKey
        
        // Test hash function
        let hash1 = try hashDLEQ(key1, key2, key3)
        let hash2 = try hashDLEQ(key1, key2, key3)
        let hash3 = try hashDLEQ(key1, key3, key2) // Different order
        
        // Same inputs should produce same hash
        #expect(hash1 == hash2)
        
        // Different order should produce different hash
        #expect(hash1 != hash3)
        
        // Hash should be 32 bytes (SHA256)
        #expect(hash1.count == 32)
    }
    
    @Test("BlindSignature with DLEQ proof")
    func testBlindSignatureWithDLEQ() async throws {
        let dleqProof = DLEQProof(e: "abcd", s: "efgh")
        let blindSig = BlindSignature(amount: 100, id: "test_id", C_: "test_signature", dleq: dleqProof)
        
        #expect(blindSig.amount == 100)
        #expect(blindSig.id == "test_id")
        #expect(blindSig.C_ == "test_signature")
        #expect(blindSig.dleq?.e == "abcd")
        #expect(blindSig.dleq?.s == "efgh")
    }
    
    @Test("Proof with DLEQ proof")
    func testProofWithDLEQ() async throws {
        let dleqProof = DLEQProof(e: "abcd", s: "efgh", r: "ijkl")
        let proof = Proof(amount: 100, id: "test_id", secret: "test_secret", C: "test_signature", dleq: dleqProof)
        
        #expect(proof.amount == 100)
        #expect(proof.id == "test_id")
        #expect(proof.secret == "test_secret")
        #expect(proof.C == "test_signature")
        #expect(proof.dleq?.e == "abcd")
        #expect(proof.dleq?.s == "efgh")
        #expect(proof.dleq?.r == "ijkl")
    }
    
    @Test("Mint info supports NUT-12")
    func testMintInfoNUT12Support() async throws {
        // Test mint info with NUT-12 support
        let nuts = ["12": NutValue.dictionary(["supported": AnyCodable(true)])]
        let mintInfo = MintInfo(nuts: nuts)
        
        #expect(mintInfo.supportsOfflineSignatureValidation())
        
        // Test mint info without NUT-12 support
        let nutsWithoutNUT12 = ["11": NutValue.dictionary(["supported": AnyCodable(true)])]
        let mintInfoWithoutNUT12 = MintInfo(nuts: nutsWithoutNUT12)
        
        #expect(!mintInfoWithoutNUT12.supportsOfflineSignatureValidation())
    }
    
    @Test("Complete DLEQ flow")
    func testCompleteDLEQFlow() async throws {
        // This test simulates the complete flow from NUT-12 specification
        
        // Setup: Mint with keypair
        let mint = try Mint()
        let mintPrivateKey = mint.keypair.privateKey
        let mintPublicKey = mint.keypair.publicKey
        
        // Step 1: Alice creates blinded message
        let secret = "complete_flow_test"
        let blindingData = try WalletBlindingData(secret: secret)
        
        // Step 2: Mint signs blinded message and creates DLEQ proof
        let blindedSignatureData = try mint.signBlindedMessage(blindingData.blindedMessage.dataRepresentation)
        let blindedSignature = try P256K.KeyAgreement.PublicKey(dataRepresentation: blindedSignatureData, format: .compressed)
        
        let dleqProof = try generateDLEQProof(
            privateKey: mintPrivateKey,
            blindedMessage: blindingData.blindedMessage,
            blindedSignature: blindedSignature
        )
        
        // Step 3: Alice verifies DLEQ proof
        let aliceVerification = try verifyDLEQProofAlice(
            proof: dleqProof,
            mintPublicKey: mintPublicKey,
            blindedMessage: blindingData.blindedMessage,
            blindedSignature: blindedSignature
        )
        #expect(aliceVerification)
        
        // Step 4: Alice unblinds signature
        let unblindedToken = try Wallet.unblindSignature(
            blindedSignature: blindedSignatureData,
            blindingData: blindingData,
            mintPublicKey: mintPublicKey
        )
        
        // Step 5: Alice creates Proof with DLEQ for Carol
        let dleqProofForCarol = DLEQProof(
            e: dleqProof.e,
            s: dleqProof.s,
            r: blindingData.blindingFactor.rawRepresentation.hexString
        )
        
        let proofForCarol = Proof(
            amount: 100,
            id: "test_id",
            secret: secret,
            C: unblindedToken.signature.hexString,
            dleq: dleqProofForCarol
        )
        
        // Step 6: Carol verifies DLEQ proof
        let signaturePoint = try P256K.KeyAgreement.PublicKey(dataRepresentation: unblindedToken.signature, format: .compressed)
        let carolVerification = try verifyDLEQProofCarol(
            proof: dleqProofForCarol,
            mintPublicKey: mintPublicKey,
            secret: secret,
            signature: signaturePoint
        )
        #expect(carolVerification)
        
        // Step 7: Verify token is still valid with mint
        let mintVerification = try mint.verifyToken(secret: secret, signature: unblindedToken.signature)
        #expect(mintVerification)
    }
    
    // MARK: - NUT-12 Test Vectors
    
    @Test("Test vector: hash_e function")
    func testVectorHashE() async throws {
        // Test vector from NUT-12 specification
        let R1 = try P256K.KeyAgreement.PublicKey(dataRepresentation: Data(hexString: "020000000000000000000000000000000000000000000000000000000000000001")!, format: .compressed)
        let R2 = try P256K.KeyAgreement.PublicKey(dataRepresentation: Data(hexString: "020000000000000000000000000000000000000000000000000000000000000001")!, format: .compressed)
        let K = try P256K.KeyAgreement.PublicKey(dataRepresentation: Data(hexString: "020000000000000000000000000000000000000000000000000000000000000001")!, format: .compressed)
        let C_ = try P256K.KeyAgreement.PublicKey(dataRepresentation: Data(hexString: "02a9acc1e48c25eeeb9289b5031cc57da9fe72f3fe2861d264bdc074209b107ba2")!, format: .compressed)
        
        let expectedHash = "a4dc034b74338c28c6bc3ea49731f2a24440fc7c4affc08b31a93fc9fbe6401e"
        
        // Calculate hash(R1, R2, K, C_)
        let hash = try hashDLEQ(R1, R2, K, C_)
        
        #expect(hash.hexString == expectedHash, "Hash should match expected value from test vector")
    }
    
    @Test("Test vector: DLEQ verification on BlindSignature")
    func testVectorDLEQBlindSignature() async throws {
        // Test vector from NUT-12 specification
        let A = try P256K.KeyAgreement.PublicKey(dataRepresentation: Data(hexString: "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")!, format: .compressed)
        let B_ = try P256K.KeyAgreement.PublicKey(dataRepresentation: Data(hexString: "02a9acc1e48c25eeeb9289b5031cc57da9fe72f3fe2861d264bdc074209b107ba2")!, format: .compressed)
        let C_ = try P256K.KeyAgreement.PublicKey(dataRepresentation: Data(hexString: "02a9acc1e48c25eeeb9289b5031cc57da9fe72f3fe2861d264bdc074209b107ba2")!, format: .compressed)
        
        let dleqProof = DLEQProof(
            e: "9818e061ee51d5c8edc3342369a554998ff7b4381c8652d724cdf46429be73d9",
            s: "9818e061ee51d5c8edc3342369a554998ff7b4381c8652d724cdf46429be73da"
        )
        
        let blindSignature = BlindSignature(
            amount: 8,
            id: "00882760bfa2eb41",
            C_: "02a9acc1e48c25eeeb9289b5031cc57da9fe72f3fe2861d264bdc074209b107ba2",
            dleq: dleqProof
        )
        
        // Verify the DLEQ proof
        let isValid = try verifyDLEQProofAlice(
            proof: dleqProof,
            mintPublicKey: A,
            blindedMessage: B_,
            blindedSignature: C_
        )
        
        #expect(isValid, "DLEQ proof should be valid according to test vector")
        
        // Also verify the blind signature structure
        #expect(blindSignature.amount == 8)
        #expect(blindSignature.id == "00882760bfa2eb41")
        #expect(blindSignature.C_ == "02a9acc1e48c25eeeb9289b5031cc57da9fe72f3fe2861d264bdc074209b107ba2")
        #expect(blindSignature.dleq?.e == dleqProof.e)
        #expect(blindSignature.dleq?.s == dleqProof.s)
    }
    
    @Test("Test vector: DLEQ verification on Proof")
    func testVectorDLEQProof() async throws {
        // Test vector from NUT-12 specification
        let A = try P256K.KeyAgreement.PublicKey(dataRepresentation: Data(hexString: "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")!, format: .compressed)
        
        let dleqProof = DLEQProof(
            e: "b31e58ac6527f34975ffab13e70a48b6d2b0d35abc4b03f0151f09ee1a9763d4",
            s: "8fbae004c59e754d71df67e392b6ae4e29293113ddc2ec86592a0431d16306d8",
            r: "a6d13fcd7a18442e6076f5e1e7c887ad5de40a019824bdfa9fe740d302e8d861"
        )
        
        let proof = Proof(
            amount: 1,
            id: "00882760bfa2eb41",
            secret: "daf4dd00a2b68a0858a80450f52c8a7d2ccf87d375e43e216e0c571f089f63e9",
            C: "024369d2d22a80ecf78f3937da9d5f30c1b9f74f0c32684d583cca0fa6a61cdcfc",
            dleq: dleqProof
        )
        
        // Verify the DLEQ proof using Carol's verification method
        let C = try P256K.KeyAgreement.PublicKey(dataRepresentation: Data(hexString: "024369d2d22a80ecf78f3937da9d5f30c1b9f74f0c32684d583cca0fa6a61cdcfc")!, format: .compressed)
        
        let isValid = try verifyDLEQProofCarol(
            proof: dleqProof,
            mintPublicKey: A,
            secret: proof.secret,
            signature: C
        )
        
        #expect(isValid, "DLEQ proof should be valid according to test vector")
        
        // Also verify the proof structure
        #expect(proof.amount == 1)
        #expect(proof.id == "00882760bfa2eb41")
        #expect(proof.secret == "daf4dd00a2b68a0858a80450f52c8a7d2ccf87d375e43e216e0c571f089f63e9")
        #expect(proof.C == "024369d2d22a80ecf78f3937da9d5f30c1b9f74f0c32684d583cca0fa6a61cdcfc")
        #expect(proof.dleq?.e == dleqProof.e)
        #expect(proof.dleq?.s == dleqProof.s)
        #expect(proof.dleq?.r == dleqProof.r)
    }
}
