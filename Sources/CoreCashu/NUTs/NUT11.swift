import Foundation
import CryptoKit
import P256K

public enum SignatureFlag: String, CaseIterable, Sendable {
    case sigInputs = "SIG_INPUTS"
    case sigAll = "SIG_ALL"
}

public struct P2PKWitness: Codable, Equatable, Sendable {
    public let signatures: [String]
    
    public init(signatures: [String]) {
        self.signatures = signatures
    }
    
    public func toJSONString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CashuError.serializationFailed
        }
        return string
    }
    
    public static func fromString(_ string: String) throws -> P2PKWitness {
        guard let data = string.data(using: .utf8) else {
            throw CashuError.deserializationFailed
        }
        return try JSONDecoder().decode(P2PKWitness.self, from: data)
    }
}

public struct P2PKSpendingCondition: Sendable {
    public let publicKey: String
    public let nonce: String
    public let signatureFlag: SignatureFlag
    public let requiredSigs: Int
    public let additionalPubkeys: [String]
    public let locktime: Int?
    public let refundPubkeys: [String]
    
    public init(
        publicKey: String,
        nonce: String? = nil,
        signatureFlag: SignatureFlag = .sigInputs,
        requiredSigs: Int = 1,
        additionalPubkeys: [String] = [],
        locktime: Int? = nil,
        refundPubkeys: [String] = []
    ) {
        self.publicKey = publicKey
        self.nonce = nonce ?? WellKnownSecret.generateNonce()
        self.signatureFlag = signatureFlag
        self.requiredSigs = requiredSigs
        self.additionalPubkeys = additionalPubkeys
        self.locktime = locktime
        self.refundPubkeys = refundPubkeys
    }
    
    public func toWellKnownSecret() -> WellKnownSecret {
        var tags: [[String]] = []
        
        tags.append(["sigflag", signatureFlag.rawValue])
        
        if requiredSigs > 1 {
            tags.append(["n_sigs", String(requiredSigs)])
        }
        
        for pubkey in additionalPubkeys {
            tags.append(["pubkeys", pubkey])
        }
        
        if let locktime = locktime {
            tags.append(["locktime", String(locktime)])
        }
        
        for refundKey in refundPubkeys {
            tags.append(["refund", refundKey])
        }
        
        let secretData = WellKnownSecret.SecretData(
            nonce: nonce,
            data: publicKey,
            tags: tags.isEmpty ? nil : tags
        )
        
        return WellKnownSecret(kind: SpendingConditionKind.p2pk, secretData: secretData)
    }
    
    public static func fromWellKnownSecret(_ secret: WellKnownSecret) throws -> P2PKSpendingCondition {
        guard secret.kind == SpendingConditionKind.p2pk else {
            throw CashuError.invalidTokenFormat
        }
        
        let publicKey = secret.secretData.data
        let nonce = secret.secretData.nonce
        var signatureFlag = SignatureFlag.sigInputs
        var requiredSigs = 1
        var additionalPubkeys: [String] = []
        var locktime: Int? = nil
        var refundPubkeys: [String] = []
        
        if let tags = secret.secretData.tags {
            for tag in tags {
                guard tag.count >= 2 else { continue }
                
                switch tag[0] {
                case "sigflag":
                    signatureFlag = SignatureFlag(rawValue: tag[1]) ?? .sigInputs
                case "n_sigs":
                    requiredSigs = Int(tag[1]) ?? 1
                case "pubkeys":
                    additionalPubkeys.append(contentsOf: tag.dropFirst())
                case "locktime":
                    locktime = Int(tag[1])
                case "refund":
                    refundPubkeys.append(contentsOf: tag.dropFirst())
                default:
                    break
                }
            }
        }
        
        return P2PKSpendingCondition(
            publicKey: publicKey,
            nonce: nonce,
            signatureFlag: signatureFlag,
            requiredSigs: requiredSigs,
            additionalPubkeys: additionalPubkeys,
            locktime: locktime,
            refundPubkeys: refundPubkeys
        )
    }
    
    public func getAllPossibleSigners() -> [String] {
        var signers = [publicKey]
        signers.append(contentsOf: additionalPubkeys)
        return signers
    }
    
    public func isExpired() -> Bool {
        guard let locktime = locktime else { return false }
        return Int(Date().timeIntervalSince1970) > locktime
    }
    
    public func canBeSpentByRefund() -> Bool {
        return isExpired() && !refundPubkeys.isEmpty
    }
    
    public func canBeSpentByAnyone() -> Bool {
        return isExpired() && refundPubkeys.isEmpty
    }
}

public extension P2PKSpendingCondition {
    static func simple(publicKey: String) -> P2PKSpendingCondition {
        return P2PKSpendingCondition(publicKey: publicKey)
    }
    
    static func multisig(
        publicKeys: [String],
        requiredSigs: Int,
        signatureFlag: SignatureFlag = .sigInputs
    ) throws -> P2PKSpendingCondition {
        guard let primaryKey = publicKeys.first else {
            throw CashuError.invalidSpendingCondition("multisig requires at least one public key")
        }
        guard requiredSigs > 0, requiredSigs <= publicKeys.count else {
            throw CashuError.invalidSpendingCondition(
                "multisig requiredSigs (\(requiredSigs)) must be in 1...\(publicKeys.count)"
            )
        }
        // Reject duplicate signing keys — repeated keys cannot strengthen N-of-M, and accepting
        // them would let `requiredSigs` be satisfied by one party signing twice.
        guard Set(publicKeys).count == publicKeys.count else {
            throw CashuError.invalidSpendingCondition("multisig public keys must be unique")
        }

        let additionalKeys = Array(publicKeys.dropFirst())

        return P2PKSpendingCondition(
            publicKey: primaryKey,
            signatureFlag: signatureFlag,
            requiredSigs: requiredSigs,
            additionalPubkeys: additionalKeys
        )
    }
    
    static func timelocked(
        publicKey: String,
        locktime: Int,
        refundPubkeys: [String] = []
    ) -> P2PKSpendingCondition {
        return P2PKSpendingCondition(
            publicKey: publicKey,
            locktime: locktime,
            refundPubkeys: refundPubkeys
        )
    }
}

public struct P2PKSignatureValidator {

    /// Validates a single BIP340 Schnorr signature over `SHA256(message)`, per NUT-11.
    ///
    /// - Parameters:
    ///   - signature: 64-byte BIP340 Schnorr signature, hex-encoded.
    ///   - publicKey: secp256k1 public key, hex-encoded — either compressed (33 bytes) or already x-only (32 bytes).
    ///   - message: UTF-8 message; the function hashes it with SHA-256 before verification.
    public static func validateSignature(
        signature: String,
        publicKey: String,
        message: String
    ) -> Bool {
        guard let messageData = message.data(using: .utf8) else {
            return false
        }
        return validateSignatureOnBytes(
            signature: signature,
            publicKey: publicKey,
            messageBytes: messageData
        )
    }

    /// Validates a single BIP340 Schnorr signature over `SHA256(messageBytes)`, per NUT-11.
    public static func validateSignatureOnBytes(
        signature: String,
        publicKey: String,
        messageBytes: Data
    ) -> Bool {
        // NUT-11 specifies libsecp256k1 64-byte Schnorr signatures over SHA-256 of the message.
        // Delegate to the BIP340 path used by NUT-20 to keep one Schnorr chokepoint.
        let messageHash = Data(SHA256.hash(data: messageBytes))
        do {
            return try NUT20SignatureManager.verifySignature(
                signature: signature,
                messageHash: messageHash,
                publicKey: publicKey
            )
        } catch {
            return false
        }
    }

    /// Counts how many distinct signers satisfy the given message; signatures and signers each
    /// credited at most once. This avoids a single key being counted multiple times by repeating
    /// its signature, and avoids one signature being credited to multiple signers.
    private static func countDistinctValidSigners(
        signatures: [String],
        signers: [String],
        validate: (_ signature: String, _ signer: String) -> Bool
    ) -> Int {
        var creditedSigners = Set<String>()
        var consumedSignatureIndices = Set<Int>()
        for signer in signers {
            for (index, signature) in signatures.enumerated() {
                if consumedSignatureIndices.contains(index) { continue }
                if validate(signature, signer) {
                    creditedSigners.insert(signer)
                    consumedSignatureIndices.insert(index)
                    break
                }
            }
        }
        return creditedSigners.count
    }

    public static func validateProofSignatures(
        proof: Proof,
        condition: P2PKSpendingCondition
    ) -> Bool {
        guard let witness = proof.getP2PKWitness() else {
            return false
        }

        // Refund branch wins outright: if the locktime has expired and the refund pubkeys are set,
        // a single valid signature from any refund key authorizes spending.
        if condition.canBeSpentByRefund() {
            for signature in witness.signatures {
                for refundKey in condition.refundPubkeys {
                    if validateSignature(signature: signature, publicKey: refundKey, message: proof.secret) {
                        return true
                    }
                }
            }
            return false
        }

        let availableSigners = condition.getAllPossibleSigners()
        let validSignatureCount = countDistinctValidSigners(
            signatures: witness.signatures,
            signers: availableSigners
        ) { signature, signer in
            validateSignature(signature: signature, publicKey: signer, message: proof.secret)
        }

        return validSignatureCount >= condition.requiredSigs
    }

    public static func validateBlindedMessageSignatures(
        blindedMessage: BlindedMessage,
        condition: P2PKSpendingCondition
    ) -> Bool {
        guard let witness = blindedMessage.getP2PKWitness(),
              let messageBytes = Data(hexString: blindedMessage.B_) else {
            return false
        }

        if condition.canBeSpentByRefund() {
            for signature in witness.signatures {
                for refundKey in condition.refundPubkeys {
                    if validateSignatureOnBytes(signature: signature, publicKey: refundKey, messageBytes: messageBytes) {
                        return true
                    }
                }
            }
            return false
        }

        let availableSigners = condition.getAllPossibleSigners()
        let validSignatureCount = countDistinctValidSigners(
            signatures: witness.signatures,
            signers: availableSigners
        ) { signature, signer in
            validateSignatureOnBytes(signature: signature, publicKey: signer, messageBytes: messageBytes)
        }

        return validSignatureCount >= condition.requiredSigs
    }
    
    public static func validateSpendingConditions(
        proofs: [Proof],
        blindedMessages: [BlindedMessage] = []
    ) -> Bool {
        var requiresAllSignatures = false
        var conditions: [P2PKSpendingCondition] = []
        
        for proof in proofs {
            guard let condition = proof.getP2PKSpendingCondition() else {
                continue
            }
            
            if condition.signatureFlag == .sigAll {
                requiresAllSignatures = true
            }
            
            conditions.append(condition)
            
            if !validateProofSignatures(proof: proof, condition: condition) {
                return false
            }
        }
        
        if requiresAllSignatures && !blindedMessages.isEmpty {
            guard let firstCondition = conditions.first else {
                return false
            }
            
            for blindedMessage in blindedMessages {
                if !validateBlindedMessageSignatures(blindedMessage: blindedMessage, condition: firstCondition) {
                    return false
                }
            }
        }
        
        return true
    }
}

