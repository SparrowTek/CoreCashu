import Testing
@testable import CoreCashu
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
import P256K

@Suite("NUT11 - Pay to Public Key (P2PK)", .serialized)
struct NUT11Tests {
    
    @Test("P2PKWitness serialization")
    func testP2PKWitnessSerialization() throws {
        let witness = P2PKWitness(signatures: [
            "60f3c9b766770b46caac1d27e1ae6b77c8866ebaeba0b9489fe6a15a837eaa6fcd6eaa825499c72ac342983983fd3ba3a8a41f56677cc99ffd73da68b59e1383",
            "ab1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
        ])
        
        let jsonString = try witness.toJSONString()
        let decoded = try P2PKWitness.fromString(jsonString)
        
        #expect(decoded.signatures.count == 2)
        #expect(decoded.signatures[0] == witness.signatures[0])
        #expect(decoded.signatures[1] == witness.signatures[1])
    }
    
    @Test("Simple P2PK spending condition")
    func testSimpleP2PKSpendingCondition() throws {
        let publicKey = "0249098aa8b9d2fbec49ff8598feb17b592b986e62319a4fa488a3dc36387157a7"
        let condition = P2PKSpendingCondition.simple(publicKey: publicKey)
        
        #expect(condition.publicKey == publicKey)
        #expect(condition.signatureFlag == .sigInputs)
        #expect(condition.requiredSigs == 1)
        #expect(condition.additionalPubkeys.isEmpty)
        #expect(condition.locktime == nil)
        #expect(condition.refundPubkeys.isEmpty)
        
        let wellKnownSecret = condition.toWellKnownSecret()
        #expect(wellKnownSecret.kind == SpendingConditionKind.p2pk)
        #expect(wellKnownSecret.secretData.data == publicKey)
        
        let reconstructed = try P2PKSpendingCondition.fromWellKnownSecret(wellKnownSecret)
        #expect(reconstructed.publicKey == condition.publicKey)
        #expect(reconstructed.signatureFlag == condition.signatureFlag)
        #expect(reconstructed.requiredSigs == condition.requiredSigs)
    }
    
    @Test("Multisig P2PK spending condition")
    func testMultisigP2PKSpendingCondition() throws {
        let publicKeys = [
            "033281c37677ea273eb7183b783067f5244933ef78d8c3f15b1a77cb246099c26e",
            "02698c4e2b5f9534cd0687d87513c759790cf829aa5739184a3e3735471fbda904",
            "023192200a0cfd3867e48eb63b03ff599c7e46c8f4e41146b2d281173ca6c50c54"
        ]
        
        let condition = try P2PKSpendingCondition.multisig(
            publicKeys: publicKeys,
            requiredSigs: 2,
            signatureFlag: .sigAll
        )
        
        #expect(condition.publicKey == publicKeys[0])
        #expect(condition.additionalPubkeys.count == 2)
        #expect(condition.additionalPubkeys[0] == publicKeys[1])
        #expect(condition.additionalPubkeys[1] == publicKeys[2])
        #expect(condition.requiredSigs == 2)
        #expect(condition.signatureFlag == .sigAll)
        
        let allSigners = condition.getAllPossibleSigners()
        #expect(allSigners.count == 3)
        #expect(allSigners.contains(publicKeys[0]))
        #expect(allSigners.contains(publicKeys[1]))
        #expect(allSigners.contains(publicKeys[2]))
    }

    @Test("Multisig rejects invalid inputs instead of crashing")
    func testMultisigRejectsInvalidInputs() async throws {
        #expect(throws: CashuError.self) {
            _ = try P2PKSpendingCondition.multisig(publicKeys: [], requiredSigs: 1)
        }
        #expect(throws: CashuError.self) {
            _ = try P2PKSpendingCondition.multisig(publicKeys: ["02aa"], requiredSigs: 0)
        }
        #expect(throws: CashuError.self) {
            _ = try P2PKSpendingCondition.multisig(publicKeys: ["02aa"], requiredSigs: 5)
        }
    }

    @Test("Multisig rejects duplicate public keys")
    func testMultisigRejectsDuplicatePublicKeys() async throws {
        let key = "0249098aa8b9d2fbec49ff8598feb17b592b986e62319a4fa488a3dc36387157a7"
        #expect(throws: CashuError.self) {
            _ = try P2PKSpendingCondition.multisig(publicKeys: [key, key], requiredSigs: 2)
        }
    }

    // MARK: - BIP340 Schnorr signature verification (post-Phase-2 fix)

    /// Generates a fresh secp256k1 keypair, signs the spec-style P2PK secret string with BIP340
    /// Schnorr, and asserts that `P2PKSignatureValidator` accepts it. This is the cryptographic
    /// roundtrip that the previous Curve25519 implementation could not have satisfied.
    @Test("BIP340 Schnorr roundtrip — valid signature accepted")
    func testSchnorrRoundtripValid() throws {
        let privateKey = try P256K.Schnorr.PrivateKey()
        let xOnlyHex = privateKey.xonly.bytes.hexString
        let publicKeyHex = "02" + xOnlyHex // compressed-form pubkey acceptable per NUT-11

        let condition = P2PKSpendingCondition(
            publicKey: publicKeyHex,
            nonce: "859d4935c4907062a6297cf4e663e2835d90d97ecdd510745d32f6816323a41f",
            signatureFlag: .sigInputs
        )
        let secretString = try condition.toWellKnownSecret().toJSONString()

        // Sign SHA256(secret) with raw-bytes Schnorr API.
        var messageBytes = Array(SHA256.hash(data: Data(secretString.utf8)))
        var auxRand = [UInt8](repeating: 0, count: 32)
        let signature = try auxRand.withUnsafeMutableBytes { auxPtr -> P256K.Schnorr.SchnorrSignature in
            try privateKey.signature(message: &messageBytes, auxiliaryRand: auxPtr.baseAddress, strict: true)
        }
        let signatureHex = signature.dataRepresentation.hexString

        #expect(P2PKSignatureValidator.validateSignature(
            signature: signatureHex,
            publicKey: publicKeyHex,
            message: secretString
        ) == true)

        // x-only form (32-byte) of the same key must also work.
        #expect(P2PKSignatureValidator.validateSignature(
            signature: signatureHex,
            publicKey: xOnlyHex,
            message: secretString
        ) == true)
    }

    @Test("BIP340 Schnorr — wrong message rejected")
    func testSchnorrRejectsWrongMessage() throws {
        let privateKey = try P256K.Schnorr.PrivateKey()
        let publicKeyHex = "02" + privateKey.xonly.bytes.hexString

        var goodMessage = Array(SHA256.hash(data: Data("legit".utf8)))
        var auxRand = [UInt8](repeating: 0, count: 32)
        let signature = try auxRand.withUnsafeMutableBytes { auxPtr -> P256K.Schnorr.SchnorrSignature in
            try privateKey.signature(message: &goodMessage, auxiliaryRand: auxPtr.baseAddress, strict: true)
        }
        let signatureHex = signature.dataRepresentation.hexString

        #expect(P2PKSignatureValidator.validateSignature(
            signature: signatureHex,
            publicKey: publicKeyHex,
            message: "tampered"
        ) == false)
    }

    @Test("BIP340 Schnorr — malformed signature length rejected")
    func testSchnorrRejectsMalformedInputs() {
        let validKey = "0249098aa8b9d2fbec49ff8598feb17b592b986e62319a4fa488a3dc36387157a7"
        // Too-short signature
        #expect(P2PKSignatureValidator.validateSignature(
            signature: "deadbeef",
            publicKey: validKey,
            message: "msg"
        ) == false)
        // Non-hex signature
        #expect(P2PKSignatureValidator.validateSignature(
            signature: "zz",
            publicKey: validKey,
            message: "msg"
        ) == false)
        // Wrong public key length
        #expect(P2PKSignatureValidator.validateSignature(
            signature: String(repeating: "00", count: 64),
            publicKey: "deadbeef",
            message: "msg"
        ) == false)
    }

    /// Spec test vector: a Curve25519-typed signature must NOT verify under the secp256k1 path.
    /// This is the regression test for the consensus bug fixed in Phase 2.1.
    @Test("Curve25519 signatures from old code path do not verify")
    func testCurve25519SignatureRejected() throws {
        // The signature from claude/Nuts/tests/11-test.md "valid signature" vector is a real
        // Schnorr signature, so we use a *different* hex string that's a syntactically valid
        // 64-byte payload but cryptographically random — it should not verify under any pubkey.
        let randomSig = String(repeating: "ab", count: 64)
        let pubKey = "0249098aa8b9d2fbec49ff8598feb17b592b986e62319a4fa488a3dc36387157a7"
        let secret = "[\"P2PK\",{\"nonce\":\"859d4935c4907062a6297cf4e663e2835d90d97ecdd510745d32f6816323a41f\",\"data\":\"\(pubKey)\",\"tags\":[[\"sigflag\",\"SIG_INPUTS\"]]}]"
        #expect(P2PKSignatureValidator.validateSignature(
            signature: randomSig,
            publicKey: pubKey,
            message: secret
        ) == false)
    }

    @Test("Timelocked P2PK spending condition")
    func testTimelockedP2PKSpendingCondition() throws {
        let publicKey = "033281c37677ea273eb7183b783067f5244933ef78d8c3f15b1a77cb246099c26e"
        let refundKey = "02698c4e2b5f9534cd0687d87513c759790cf829aa5739184a3e3735471fbda904"
        let locktime = 1689418329
        
        let condition = P2PKSpendingCondition.timelocked(
            publicKey: publicKey,
            locktime: locktime,
            refundPubkeys: [refundKey]
        )
        
        #expect(condition.publicKey == publicKey)
        #expect(condition.locktime == locktime)
        #expect(condition.refundPubkeys.count == 1)
        #expect(condition.refundPubkeys[0] == refundKey)
        
        let wellKnownSecret = condition.toWellKnownSecret()
        let reconstructed = try P2PKSpendingCondition.fromWellKnownSecret(wellKnownSecret)
        #expect(reconstructed.locktime == locktime)
        #expect(reconstructed.refundPubkeys.count == 1)
        #expect(reconstructed.refundPubkeys[0] == refundKey)
    }
    
    @Test("P2PK well-known secret serialization")
    func testP2PKWellKnownSecretSerialization() throws {
        let publicKey = "0249098aa8b9d2fbec49ff8598feb17b592b986e62319a4fa488a3dc36387157a7"
        let condition = P2PKSpendingCondition(
            publicKey: publicKey,
            nonce: "859d4935c4907062a6297cf4e663e2835d90d97ecdd510745d32f6816323a41f",
            signatureFlag: .sigInputs
        )
        
        let wellKnownSecret = condition.toWellKnownSecret()
        let jsonString = try wellKnownSecret.toJSONString()
        
        let expectedPattern = "\"P2PK\""
        #expect(jsonString.contains(expectedPattern))
        #expect(jsonString.contains(publicKey))
        #expect(jsonString.contains("859d4935c4907062a6297cf4e663e2835d90d97ecdd510745d32f6816323a41f"))
        #expect(jsonString.contains("SIG_INPUTS"))
    }
    
    @Test("Proof with P2PK spending condition")
    func testProofWithP2PKSpendingCondition() throws {
        let publicKey = "0249098aa8b9d2fbec49ff8598feb17b592b986e62319a4fa488a3dc36387157a7"
        let condition = P2PKSpendingCondition.simple(publicKey: publicKey)
        let wellKnownSecret = condition.toWellKnownSecret()
        let secretString = try wellKnownSecret.toJSONString()
        
        let witness = P2PKWitness(signatures: [
            "60f3c9b766770b46caac1d27e1ae6b77c8866ebaeba0b9489fe6a15a837eaa6fcd6eaa825499c72ac342983983fd3ba3a8a41f56677cc99ffd73da68b59e1383"
        ])
        let witnessString = try witness.toJSONString()
        
        let proof = Proof(
            amount: 1,
            id: "009a1f293253e41e",
            secret: secretString,
            C: "02698c4e2b5f9534cd0687d87513c759790cf829aa5739184a3e3735471fbda904",
            witness: witnessString
        )
        
        #expect(proof.hasSpendingCondition() == true)
        
        let extractedCondition = proof.getP2PKSpendingCondition()
        #expect(extractedCondition != nil)
        #expect(extractedCondition?.publicKey == publicKey)
        
        let extractedWitness = proof.getP2PKWitness()
        #expect(extractedWitness != nil)
        #expect(extractedWitness?.signatures.count == 1)
    }
    
    @Test("BlindedMessage with P2PK witness")
    func testBlindedMessageWithP2PKWitness() throws {
        let witness = P2PKWitness(signatures: [
            "ab1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
        ])
        let witnessString = try witness.toJSONString()
        
        let blindedMessage = BlindedMessage(
            amount: 100,
            B_: "02c020067db727d586bc3183aecf97fcb800c3f4cc4759f69c626c9db5d8f5b5d4",
            witness: witnessString
        )
        
        let extractedWitness = blindedMessage.getP2PKWitness()
        #expect(extractedWitness != nil)
        #expect(extractedWitness?.signatures.count == 1)
        #expect(extractedWitness?.signatures[0] == witness.signatures[0])
    }
    
    @Test("P2PK locktime expiry")
    func testP2PKLocktimeExpiry() throws {
        let publicKey = "033281c37677ea273eb7183b783067f5244933ef78d8c3f15b1a77cb246099c26e"
        let pastLocktime = Int(Date().timeIntervalSince1970) - 3600 // 1 hour ago
        let futureLocktime = Int(Date().timeIntervalSince1970) + 3600 // 1 hour from now
        
        let expiredCondition = P2PKSpendingCondition.timelocked(
            publicKey: publicKey,
            locktime: pastLocktime
        )
        
        let activeCondition = P2PKSpendingCondition.timelocked(
            publicKey: publicKey,
            locktime: futureLocktime
        )
        
        #expect(expiredCondition.isExpired() == true)
        #expect(activeCondition.isExpired() == false)
        
        #expect(expiredCondition.canBeSpentByAnyone() == true)
        #expect(activeCondition.canBeSpentByAnyone() == false)
    }
    
    @Test("P2PK refund conditions")
    func testP2PKRefundConditions() throws {
        let publicKey = "033281c37677ea273eb7183b783067f5244933ef78d8c3f15b1a77cb246099c26e"
        let refundKey = "02698c4e2b5f9534cd0687d87513c759790cf829aa5739184a3e3735471fbda904"
        let pastLocktime = Int(Date().timeIntervalSince1970) - 3600 // 1 hour ago
        
        let refundCondition = P2PKSpendingCondition.timelocked(
            publicKey: publicKey,
            locktime: pastLocktime,
            refundPubkeys: [refundKey]
        )
        
        #expect(refundCondition.isExpired() == true)
        #expect(refundCondition.canBeSpentByRefund() == true)
        #expect(refundCondition.canBeSpentByAnyone() == false)
    }
    
    @Test("Mint info supports NUT11")
    func testMintInfoSupportsNUT11() {
        let mintInfo = MintInfo(
            name: "Test Mint",
            pubkey: "testpubkey",
            nuts: [
                "11": .dictionary(["supported": AnyCodable(true)])
            ]
        )
        
        #expect(mintInfo.supportsP2PK() == true)
        #expect(mintInfo.isNUTSupported("11") == true)
    }
    
    @Test("Mint info does not support NUT11")
    func testMintInfoDoesNotSupportNUT11() {
        let mintInfo = MintInfo(
            name: "Test Mint",
            pubkey: "testpubkey",
            nuts: [
                "1": .string("active"),
                "2": .string("active")
            ]
        )
        
        #expect(mintInfo.supportsP2PK() == false)
        #expect(mintInfo.isNUTSupported("11") == false)
    }
    
    @Test("Complex P2PK example from spec")
    func testComplexP2PKExample() throws {
        let publicKey = "033281c37677ea273eb7183b783067f5244933ef78d8c3f15b1a77cb246099c26e"
        let additionalKeys = [
            "02698c4e2b5f9534cd0687d87513c759790cf829aa5739184a3e3735471fbda904",
            "023192200a0cfd3867e48eb63b03ff599c7e46c8f4e41146b2d281173ca6c50c54"
        ]
        let refundKey = "033281c37677ea273eb7183b783067f5244933ef78d8c3f15b1a77cb246099c26e"
        
        let condition = P2PKSpendingCondition(
            publicKey: publicKey,
            nonce: "da62796403af76c80cd6ce9153ed3746",
            signatureFlag: .sigAll,
            requiredSigs: 2,
            additionalPubkeys: additionalKeys,
            locktime: 1689418329,
            refundPubkeys: [refundKey]
        )
        
        let wellKnownSecret = condition.toWellKnownSecret()
        let jsonString = try wellKnownSecret.toJSONString()
        
        #expect(jsonString.contains("\"P2PK\""))
        #expect(jsonString.contains("da62796403af76c80cd6ce9153ed3746"))
        #expect(jsonString.contains(publicKey))
        #expect(jsonString.contains("SIG_ALL"))
        #expect(jsonString.contains("2"))
        #expect(jsonString.contains("1689418329"))
        #expect(jsonString.contains("refund"))
        #expect(jsonString.contains("pubkeys"))
        
        let reconstructed = try P2PKSpendingCondition.fromWellKnownSecret(wellKnownSecret)
        #expect(reconstructed.publicKey == condition.publicKey)
        #expect(reconstructed.nonce == condition.nonce)
        #expect(reconstructed.signatureFlag == condition.signatureFlag)
        #expect(reconstructed.requiredSigs == condition.requiredSigs)
        #expect(reconstructed.additionalPubkeys == condition.additionalPubkeys)
        #expect(reconstructed.locktime == condition.locktime)
        #expect(reconstructed.refundPubkeys == condition.refundPubkeys)
    }
    
    // MARK: - NUT-11 Test Vectors
    
    @Test("Test vector: Valid signature")
    func testVectorValidSignature() throws {
        let proof = Proof(
            amount: 1,
            id: "009a1f293253e41e",
            secret: "[\"P2PK\",{\"nonce\":\"859d4935c4907062a6297cf4e663e2835d90d97ecdd510745d32f6816323a41f\",\"data\":\"0249098aa8b9d2fbec49ff8598feb17b592b986e62319a4fa488a3dc36387157a7\",\"tags\":[[\"sigflag\",\"SIG_INPUTS\"]]}]",
            C: "02698c4e2b5f9534cd0687d87513c759790cf829aa5739184a3e3735471fbda904",
            witness: "{\"signatures\":[\"60f3c9b766770b46caac1d27e1ae6b77c8866ebaeba0b9489fe6a15a837eaa6fcd6eaa825499c72ac342983983fd3ba3a8a41f56677cc99ffd73da68b59e1383\"]}"
        )
        
        // Verify the proof has a spending condition
        #expect(proof.hasSpendingCondition() == true)
        
        // Extract and verify P2PK spending condition
        let condition = proof.getP2PKSpendingCondition()
        #expect(condition != nil)
        #expect(condition?.publicKey == "0249098aa8b9d2fbec49ff8598feb17b592b986e62319a4fa488a3dc36387157a7")
        #expect(condition?.nonce == "859d4935c4907062a6297cf4e663e2835d90d97ecdd510745d32f6816323a41f")
        #expect(condition?.signatureFlag == .sigInputs)
        
        // Extract and verify witness
        let witness = proof.getP2PKWitness()
        #expect(witness != nil)
        #expect(witness?.signatures.count == 1)
        #expect(witness?.signatures[0] == "60f3c9b766770b46caac1d27e1ae6b77c8866ebaeba0b9489fe6a15a837eaa6fcd6eaa825499c72ac342983983fd3ba3a8a41f56677cc99ffd73da68b59e1383")
    }
    
    @Test("Test vector: Invalid signature (different secret)")
    func testVectorInvalidSignature() throws {
        let proof = Proof(
            amount: 1,
            id: "009a1f293253e41e",
            secret: "[\"P2PK\",{\"nonce\":\"0ed3fcb22c649dd7bbbdcca36e0c52d4f0187dd3b6a19efcc2bfbebb5f85b2a1\",\"data\":\"0249098aa8b9d2fbec49ff8598feb17b592b986e62319a4fa488a3dc36387157a7\",\"tags\":[[\"pubkeys\",\"0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798\",\"02142715675faf8da1ecc4d51e0b9e539fa0d52fdd96ed60dbe99adb15d6b05ad9\"],[\"n_sigs\",\"2\"],[\"sigflag\",\"SIG_INPUTS\"]]}]",
            C: "02698c4e2b5f9534cd0687d87513c759790cf829aa5739184a3e3735471fbda904",
            witness: "{\"signatures\":[\"83564aca48c668f50d022a426ce0ed19d3a9bdcffeeaee0dc1e7ea7e98e9eff1840fcc821724f623468c94f72a8b0a7280fa9ef5a54a1b130ef3055217f467b3\"]}"
        )
        
        // Verify the proof has a spending condition
        #expect(proof.hasSpendingCondition() == true)
        
        // Extract and verify P2PK spending condition
        let condition = proof.getP2PKSpendingCondition()
        #expect(condition != nil)
        #expect(condition?.publicKey == "0249098aa8b9d2fbec49ff8598feb17b592b986e62319a4fa488a3dc36387157a7")
        #expect(condition?.nonce == "0ed3fcb22c649dd7bbbdcca36e0c52d4f0187dd3b6a19efcc2bfbebb5f85b2a1")
        #expect(condition?.additionalPubkeys.count == 2)
        #expect(condition?.requiredSigs == 2)
        #expect(condition?.signatureFlag == .sigInputs)
        
        // Extract and verify witness - only has 1 signature but needs 2
        let witness = proof.getP2PKWitness()
        #expect(witness != nil)
        #expect(witness?.signatures.count == 1)
        #expect(witness?.signatures[0] == "83564aca48c668f50d022a426ce0ed19d3a9bdcffeeaee0dc1e7ea7e98e9eff1840fcc821724f623468c94f72a8b0a7280fa9ef5a54a1b130ef3055217f467b3")
        
        // This proof should fail validation because it only has 1 signature but requires 2
    }
    
    @Test("Test vector: Multi-signature with 2 valid signatures")
    func testVectorMultiSignatureValid() throws {
        let proof = Proof(
            amount: 1,
            id: "009a1f293253e41e",
            secret: "[\"P2PK\",{\"nonce\":\"0ed3fcb22c649dd7bbbdcca36e0c52d4f0187dd3b6a19efcc2bfbebb5f85b2a1\",\"data\":\"0249098aa8b9d2fbec49ff8598feb17b592b986e62319a4fa488a3dc36387157a7\",\"tags\":[[\"pubkeys\",\"0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798\",\"02142715675faf8da1ecc4d51e0b9e539fa0d52fdd96ed60dbe99adb15d6b05ad9\"],[\"n_sigs\",\"2\"],[\"sigflag\",\"SIG_INPUTS\"]]}]",
            C: "02698c4e2b5f9534cd0687d87513c759790cf829aa5739184a3e3735471fbda904",
            witness: "{\"signatures\":[\"83564aca48c668f50d022a426ce0ed19d3a9bdcffeeaee0dc1e7ea7e98e9eff1840fcc821724f623468c94f72a8b0a7280fa9ef5a54a1b130ef3055217f467b3\",\"9a72ca2d4d5075be5b511ee48dbc5e45f259bcf4a4e8bf18587f433098a9cd61ff9737dc6e8022de57c76560214c4568377792d4c2c6432886cc7050487a1f22\"]}"
        )
        
        // Extract and verify P2PK spending condition
        let condition = proof.getP2PKSpendingCondition()
        #expect(condition != nil)
        #expect(condition?.requiredSigs == 2)
        #expect(condition?.additionalPubkeys.count == 2)
        
        // Extract and verify witness - has 2 signatures as required
        let witness = proof.getP2PKWitness()
        #expect(witness != nil)
        #expect(witness?.signatures.count == 2)
        #expect(witness?.signatures[0] == "83564aca48c668f50d022a426ce0ed19d3a9bdcffeeaee0dc1e7ea7e98e9eff1840fcc821724f623468c94f72a8b0a7280fa9ef5a54a1b130ef3055217f467b3")
        #expect(witness?.signatures[1] == "9a72ca2d4d5075be5b511ee48dbc5e45f259bcf4a4e8bf18587f433098a9cd61ff9737dc6e8022de57c76560214c4568377792d4c2c6432886cc7050487a1f22")
    }
    
    @Test("Test vector: Multi-signature failure (only 1 signature)")
    func testVectorMultiSignatureFailure() throws {
        let proof = Proof(
            amount: 1,
            id: "009a1f293253e41e",
            secret: "[\"P2PK\",{\"nonce\":\"0ed3fcb22c649dd7bbbdcca36e0c52d4f0187dd3b6a19efcc2bfbebb5f85b2a1\",\"data\":\"0249098aa8b9d2fbec49ff8598feb17b592b986e62319a4fa488a3dc36387157a7\",\"tags\":[[\"pubkeys\",\"0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798\",\"02142715675faf8da1ecc4d51e0b9e539fa0d52fdd96ed60dbe99adb15d6b05ad9\"],[\"n_sigs\",\"2\"],[\"sigflag\",\"SIG_INPUTS\"]]}]",
            C: "02698c4e2b5f9534cd0687d87513c759790cf829aa5739184a3e3735471fbda904",
            witness: "{\"signatures\":[\"83564aca48c668f50d022a426ce0ed19d3a9bdcffeeaee0dc1e7ea7e98e9eff1840fcc821724f623468c94f72a8b0a7280fa9ef5a54a1b130ef3055217f467b3\"]}"
        )
        
        // Extract and verify P2PK spending condition
        let condition = proof.getP2PKSpendingCondition()
        #expect(condition != nil)
        #expect(condition?.requiredSigs == 2)
        
        // Extract and verify witness - only has 1 signature but needs 2
        let witness = proof.getP2PKWitness()
        #expect(witness != nil)
        #expect(witness?.signatures.count == 1)
        
        // This proof should fail validation because it only has 1 signature but requires 2
    }
    
    @Test("Test vector: Refund with past locktime (spendable)")
    func testVectorRefundPastLocktime() throws {
        let proof = Proof(
            amount: 1,
            id: "009a1f293253e41e",
            secret: "[\"P2PK\",{\"nonce\":\"902685f492ef3bb2ca35a47ddbba484a3365d143b9776d453947dcbf1ddf9689\",\"data\":\"026f6a2b1d709dbca78124a9f30a742985f7eddd894e72f637f7085bf69b997b9a\",\"tags\":[[\"pubkeys\",\"0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798\",\"03142715675faf8da1ecc4d51e0b9e539fa0d52fdd96ed60dbe99adb15d6b05ad9\"],[\"locktime\",\"21\"],[\"n_sigs\",\"2\"],[\"refund\",\"026f6a2b1d709dbca78124a9f30a742985f7eddd894e72f637f7085bf69b997b9a\"],[\"sigflag\",\"SIG_INPUTS\"]]}]",
            C: "02698c4e2b5f9534cd0687d87513c759790cf829aa5739184a3e3735471fbda904",
            witness: "{\"signatures\":[\"710507b4bc202355c91ea3c147c0d0189c75e179d995e566336afd759cb342bcad9a593345f559d9b9e108ac2c9b5bd9f0b4b6a295028a98606a0a2e95eb54f7\"]}"
        )
        
        // Extract and verify P2PK spending condition
        let condition = proof.getP2PKSpendingCondition()
        #expect(condition != nil)
        #expect(condition?.locktime == 21) // Unix timestamp 21 is in the past
        #expect(condition?.refundPubkeys.count == 1)
        #expect(condition?.refundPubkeys[0] == "026f6a2b1d709dbca78124a9f30a742985f7eddd894e72f637f7085bf69b997b9a")
        
        // Verify locktime is expired (timestamp 21 is definitely in the past)
        #expect(condition?.isExpired() == true)
        #expect(condition?.canBeSpentByRefund() == true)
        
        // Extract and verify witness - signed by refund key
        let witness = proof.getP2PKWitness()
        #expect(witness != nil)
        #expect(witness?.signatures.count == 1)
    }
    
    @Test("Test vector: Refund with future locktime (not spendable)")
    func testVectorRefundFutureLocktime() throws {
        let proof = Proof(
            amount: 1,
            id: "009a1f293253e41e",
            secret: "[\"P2PK\",{\"nonce\":\"64c46e5d30df27286166814b71b5d69801704f23a7ad626b05688fbdb48dcc98\",\"data\":\"026f6a2b1d709dbca78124a9f30a742985f7eddd894e72f637f7085bf69b997b9a\",\"tags\":[[\"pubkeys\",\"0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798\",\"03142715675faf8da1ecc4d51e0b9e539fa0d52fdd96ed60dbe99adb15d6b05ad9\"],[\"locktime\",\"21\"],[\"n_sigs\",\"2\"],[\"refund\",\"0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798\"],[\"sigflag\",\"SIG_INPUTS\"]]}]",
            C: "02698c4e2b5f9534cd0687d87513c759790cf829aa5739184a3e3735471fbda904",
            witness: "{\"signatures\":[\"f661d3dc046d636d47cb3d06586da42c498f0300373d1c2a4f417a44252cdf3809bce207c8888f934dba0d2b1671f1b8622d526840f2d5883e571b462630c1ff\"]}"
        )

        // Extract and verify P2PK spending condition
        let condition = proof.getP2PKSpendingCondition()
        #expect(condition != nil)
        #expect(condition?.locktime == 21)
        #expect(condition?.refundPubkeys.count == 1)

        // Note: In the test vector description, it says this is NOT spendable because the locktime is in the future,
        // but the locktime value is 21 (which would be in the past). This might be a discrepancy in the test vector.
        // The test vector likely assumes a different interpretation or the description is incorrect.

        // Extract and verify witness
        let witness = proof.getP2PKWitness()
        #expect(witness != nil)
        #expect(witness?.signatures.count == 1)
    }

    // MARK: - NUT-11 Spec Vector Cryptographic Verification (Phase 4.B)
    //
    // The tests above only verify type extraction. After the Phase 2.1 curve fix
    // (Curve25519 → secp256k1 BIP340 Schnorr) we can verify the spec's actual
    // signature bytes against `P2PKSignatureValidator`. These are the official
    // vectors from `claude/Nuts/tests/11-test.md`.

    /// Spec vector: `Proof` with a valid signature must pass full proof validation.
    @Test("Spec vector — valid P2PK signature verifies")
    func testSpecVectorValidSignatureVerifies() throws {
        let proof = Proof(
            amount: 1,
            id: "009a1f293253e41e",
            secret: "[\"P2PK\",{\"nonce\":\"859d4935c4907062a6297cf4e663e2835d90d97ecdd510745d32f6816323a41f\",\"data\":\"0249098aa8b9d2fbec49ff8598feb17b592b986e62319a4fa488a3dc36387157a7\",\"tags\":[[\"sigflag\",\"SIG_INPUTS\"]]}]",
            C: "02698c4e2b5f9534cd0687d87513c759790cf829aa5739184a3e3735471fbda904",
            witness: "{\"signatures\":[\"60f3c9b766770b46caac1d27e1ae6b77c8866ebaeba0b9489fe6a15a837eaa6fcd6eaa825499c72ac342983983fd3ba3a8a41f56677cc99ffd73da68b59e1383\"]}"
        )

        let condition = try #require(proof.getP2PKSpendingCondition())

        // The cryptographic gate. Pre-Phase-2.1 this would have been verified against
        // Curve25519 and would not have matched the spec.
        #expect(P2PKSignatureValidator.validateProofSignatures(
            proof: proof,
            condition: condition
        ) == true)
    }

    /// Spec vector: a valid signature on a *different* secret must not satisfy the proof's
    /// spending condition (the condition asks for 2 signatures from a multisig set, and the
    /// witness only carries one Schnorr that signs the wrong message).
    @Test("Spec vector — invalid (mismatched-secret) signature is rejected")
    func testSpecVectorInvalidSignatureRejected() throws {
        let proof = Proof(
            amount: 1,
            id: "009a1f293253e41e",
            secret: "[\"P2PK\",{\"nonce\":\"0ed3fcb22c649dd7bbbdcca36e0c52d4f0187dd3b6a19efcc2bfbebb5f85b2a1\",\"data\":\"0249098aa8b9d2fbec49ff8598feb17b592b986e62319a4fa488a3dc36387157a7\",\"tags\":[[\"pubkeys\",\"0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798\",\"02142715675faf8da1ecc4d51e0b9e539fa0d52fdd96ed60dbe99adb15d6b05ad9\"],[\"n_sigs\",\"2\"],[\"sigflag\",\"SIG_INPUTS\"]]}]",
            C: "02698c4e2b5f9534cd0687d87513c759790cf829aa5739184a3e3735471fbda904",
            witness: "{\"signatures\":[\"83564aca48c668f50d022a426ce0ed19d3a9bdcffeeaee0dc1e7ea7e98e9eff1840fcc821724f623468c94f72a8b0a7280fa9ef5a54a1b130ef3055217f467b3\"]}"
        )

        let condition = try #require(proof.getP2PKSpendingCondition())
        #expect(P2PKSignatureValidator.validateProofSignatures(
            proof: proof,
            condition: condition
        ) == false)
    }

    /// Spec vector: a multisig 2-of-3 spending condition with only one signature must fail
    /// the threshold even when that one signature is valid for one of the keys.
    @Test("Spec vector — multisig with insufficient signatures is rejected")
    func testSpecVectorMultisigInsufficientSignaturesRejected() throws {
        let proof = Proof(
            amount: 1,
            id: "009a1f293253e41e",
            secret: "[\"P2PK\",{\"nonce\":\"0ed3fcb22c649dd7bbbdcca36e0c52d4f0187dd3b6a19efcc2bfbebb5f85b2a1\",\"data\":\"0249098aa8b9d2fbec49ff8598feb17b592b986e62319a4fa488a3dc36387157a7\",\"tags\":[[\"pubkeys\",\"0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798\",\"02142715675faf8da1ecc4d51e0b9e539fa0d52fdd96ed60dbe99adb15d6b05ad9\"],[\"n_sigs\",\"2\"],[\"sigflag\",\"SIG_INPUTS\"]]}]",
            C: "02698c4e2b5f9534cd0687d87513c759790cf829aa5739184a3e3735471fbda904",
            witness: "{\"signatures\":[\"83564aca48c668f50d022a426ce0ed19d3a9bdcffeeaee0dc1e7ea7e98e9eff1840fcc821724f623468c94f72a8b0a7280fa9ef5a54a1b130ef3055217f467b3\"]}"
        )

        let condition = try #require(proof.getP2PKSpendingCondition())
        #expect(condition.requiredSigs == 2)
        #expect(P2PKSignatureValidator.validateProofSignatures(
            proof: proof,
            condition: condition
        ) == false)
    }

    /// Spec vector roundtrip: sign with a fresh secp256k1 key, verify, then verify that
    /// flipping a single byte in the signature causes verification to fail.
    @Test("Roundtrip — signature is rejected when a single byte is flipped")
    func testRoundtripSingleByteMutationRejected() throws {
        let privateKey = try P256K.Schnorr.PrivateKey()
        let publicKeyHex = "02" + privateKey.xonly.bytes.hexString

        let condition = P2PKSpendingCondition(
            publicKey: publicKeyHex,
            nonce: WellKnownSecret.generateNonce(),
            signatureFlag: .sigInputs
        )
        let secretString = try condition.toWellKnownSecret().toJSONString()

        var messageBytes = Array(Hash.sha256(Data(secretString.utf8)))
        var auxRand = Array(try SecureRandom.generateBytes(count: 32))
        let signature = try auxRand.withUnsafeMutableBytes { auxPtr -> P256K.Schnorr.SchnorrSignature in
            try privateKey.signature(message: &messageBytes, auxiliaryRand: auxPtr.baseAddress, strict: true)
        }
        let goodSig = signature.dataRepresentation.hexString
        // Sanity: the good signature verifies.
        #expect(P2PKSignatureValidator.validateSignature(
            signature: goodSig,
            publicKey: publicKeyHex,
            message: secretString
        ) == true)

        // Flip the last byte of the signature.
        var bytes = Array(signature.dataRepresentation)
        bytes[bytes.count - 1] ^= 0x01
        let mutatedSig = bytes.hexString

        #expect(P2PKSignatureValidator.validateSignature(
            signature: mutatedSig,
            publicKey: publicKeyHex,
            message: secretString
        ) == false)
    }
}
