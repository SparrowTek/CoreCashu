//
//  CashuWallet+Restore.swift
//  CoreCashu
//
//  Wallet restoration and deterministic secret operations (NUT-09, NUT-13)
//

import Foundation
import P256K

// MARK: - NUT-13: Deterministic Secrets

public extension CashuWallet {
    
    /// Check if wallet supports deterministic secrets
    var supportsDeterministicSecrets: Bool {
        return deterministicDerivation != nil
    }
    
    /// Generate a new mnemonic phrase
    /// - Parameter strength: Strength in bits (128, 160, 192, 224, or 256)
    /// - Returns: BIP39 mnemonic phrase
    static func generateMnemonic(strength: Int = 128) throws -> String {
        // Convert int strength to BIP39.Strength enum
        guard let bip39Strength = BIP39.Strength(rawValue: strength) else {
            throw CashuError.invalidMnemonic
        }
        
        // Generate mnemonic using BIP39 implementation
        return try BIP39.generateMnemonic(strength: bip39Strength)
    }
    
    /// Validate a mnemonic phrase
    /// - Parameter mnemonic: The mnemonic phrase to validate
    /// - Returns: True if valid
    static func validateMnemonic(_ mnemonic: String) -> Bool {
        return BIP39.validateMnemonic(mnemonic)
    }
    
    /// Initialize wallet from secure store (restore existing wallet)
    /// - Parameters:
    ///   - configuration: Wallet configuration
    ///   - passphrase: Optional BIP39 passphrase
    ///   - proofStorage: Optional custom proof storage
    ///   - counterStorage: Optional custom counter storage
    ///   - secureStore: Secure storage implementation to restore from
    /// - Returns: A new wallet instance
    /// - Throws: If no mnemonic is stored in secure store
    static func restoreFromSecureStore(
        configuration: WalletConfiguration,
        passphrase: String = "",
        proofStorage: (any ProofStorage)? = nil,
        counterStorage: (any KeysetCounterStorage)? = nil,
        secureStore: any SecureStore
    ) async throws -> CashuWallet {
        guard let mnemonic = try await secureStore.loadMnemonic() else {
            throw CashuError.noKeychainData
        }
        
        return try await CashuWallet(
            configuration: configuration,
            mnemonic: mnemonic,
            passphrase: passphrase,
            proofStorage: proofStorage,
            counterStorage: counterStorage,
            secureStore: secureStore
        )
    }
    
    /// Restore wallet from seed phrase (NUT-13)
    /// - Parameters:
    ///   - batchSize: Number of proofs to restore per batch (default 100)
    ///   - onProgress: Progress callback
    /// - Returns: Total restored balance
    @discardableResult
    func restoreFromSeed(
        batchSize: Int = RestorationConstants.defaultBatchSize,
        onProgress: ((RestorationProgress) async -> Void)? = nil
    ) async throws -> Int {
        guard let derivation = deterministicDerivation else {
            throw CashuError.walletNotInitializedWithMnemonic
        }
        
        guard isReady else {
            throw CashuError.walletNotInitialized
        }
        
        let restoration = WalletRestoration(
            derivation: derivation,
            counterManager: keysetCounterManager
        )
        
        var totalRestoredBalance = 0
        var restorationErrors: [String: any Error] = [:]
        
        // Restore for each active keyset
        for (keysetID, _) in currentKeysets {
            guard currentKeysetInfos[keysetID]?.active ?? false else {
                continue
            }
            
            do {
                let balance = try await restoreKeyset(
                    keysetID: keysetID,
                    restoration: restoration,
                    batchSize: batchSize,
                    onProgress: onProgress
                )
                totalRestoredBalance += balance
            } catch {
                // Store error but continue with other keysets
                restorationErrors[keysetID] = error
                
                // Report error in progress
                if let onProgress = onProgress {
                    let progress = RestorationProgress(
                        keysetID: keysetID,
                        currentCounter: 0,
                        totalProofsFound: 0,
                        unspentProofsFound: 0,
                        consecutiveEmptyBatches: 0,
                        isComplete: true,
                        error: error
                    )
                    await onProgress(progress)
                }
            }
        }
        
        // If all keysets failed, throw the first error
        if restorationErrors.count == currentKeysets.count,
           let firstError = restorationErrors.values.first {
            throw firstError
        }
        
        return totalRestoredBalance
    }
    
    /// Get current keyset counters
    func getKeysetCounters() async -> [String: UInt32] {
        return await keysetCounterManager.getAllCounters()
    }
}

// MARK: - Internal Restoration Methods

extension CashuWallet {
    
    /// Restore a single keyset
    internal func restoreKeyset(
        keysetID: String,
        restoration: WalletRestoration,
        batchSize: Int,
        onProgress: ((RestorationProgress) async -> Void)?
    ) async throws -> Int {
        let maxEmptyBatches = RestorationConstants.maxEmptyBatches
        var totalRestoredBalance = 0
        var consecutiveEmptyBatches = 0
        var currentCounter = await keysetCounterManager.getCounter(for: keysetID)
        var totalProofsFound = 0
        var unspentProofsFound = 0
        
        while consecutiveEmptyBatches < maxEmptyBatches {
            // Generate blinded messages for this batch
            let blindedMessagesWithFactors = try await restoration.generateBlindedMessages(
                keysetID: keysetID,
                startCounter: currentCounter,
                batchSize: batchSize
            )
            
            let blindedMessages = blindedMessagesWithFactors.map { $0.0 }
            let blindingFactors = blindedMessagesWithFactors.map { $0.1 }
            
            // Request signatures from mint using NUT-09
            let blindedSignatures = try await requestRestore(
                blindedMessages: blindedMessages,
                keysetID: keysetID
            )
            
            if blindedSignatures.isEmpty {
                consecutiveEmptyBatches += 1
            } else {
                consecutiveEmptyBatches = 0
                
                // Generate secrets for unblinding
                var secrets: [String] = []
                for i in 0..<blindedSignatures.count {
                    let secret = try restoration.derivation.deriveSecret(
                        keysetID: keysetID,
                        counter: currentCounter + UInt32(i)
                    )
                    secrets.append(secret)
                }
                
                guard let keyset = currentKeysets[keysetID] else {
                    throw CashuError.keysetNotFound
                }

                // Restore proofs with amount-specific mint keys.
                var restoredProofs: [Proof] = []
                for (index, blindedSignature) in blindedSignatures.enumerated() {
                    guard index < blindingFactors.count, index < secrets.count else {
                        throw CashuError.mismatchedArrayLengths
                    }
                    guard let publicKeyHex = keyset.keys[String(blindedSignature.amount)],
                          let publicKeyData = Data(hexString: publicKeyHex),
                          let mintPublicKey = try? P256K.KeyAgreement.PublicKey(dataRepresentation: publicKeyData, format: .compressed) else {
                        throw CashuError.keysetNotFound
                    }

                    let restored = try restoration.restoreProofs(
                        blindedSignatures: [blindedSignature],
                        blindingFactors: [blindingFactors[index]],
                        secrets: [secrets[index]],
                        keysetID: keysetID,
                        mintPublicKey: mintPublicKey
                    )
                    restoredProofs.append(contentsOf: restored)
                }
                
                // Check proof states
                let stateResult = try await checkProofStates(restoredProofs)
                
                // Separate spent and unspent proofs
                var unspentProofs: [Proof] = []
                for result in stateResult.results {
                    if result.stateInfo.state == .unspent {
                        unspentProofs.append(result.proof)
                    }
                }
                
                // Add unspent proofs to wallet
                if !unspentProofs.isEmpty {
                    try await proofManager.addProofs(unspentProofs)
                    totalRestoredBalance += unspentProofs.reduce(0) { $0 + $1.amount }
                    unspentProofsFound += unspentProofs.count
                }
                
                totalProofsFound += restoredProofs.count
            }
            
            currentCounter += UInt32(batchSize)
            
            // Report progress
            if let onProgress = onProgress {
                let progress = RestorationProgress(
                    keysetID: keysetID,
                    currentCounter: currentCounter,
                    totalProofsFound: totalProofsFound,
                    unspentProofsFound: unspentProofsFound,
                    consecutiveEmptyBatches: consecutiveEmptyBatches,
                    isComplete: false
                )
                await onProgress(progress)
            }
        }
        
        // Update counter for this keyset
        // Use safe arithmetic to prevent underflow
        let batchAdjustment = min(currentCounter, UInt32(maxEmptyBatches * batchSize))
        let finalCounter = currentCounter - batchAdjustment + UInt32(totalProofsFound)
        await keysetCounterManager.setCounter(for: keysetID, value: finalCounter + 1)
        
        // Report completion for this keyset
        if let onProgress = onProgress {
            let progress = RestorationProgress(
                keysetID: keysetID,
                currentCounter: finalCounter,
                totalProofsFound: totalProofsFound,
                unspentProofsFound: unspentProofsFound,
                consecutiveEmptyBatches: maxEmptyBatches,
                isComplete: true
            )
            await onProgress(progress)
        }
        
        return totalRestoredBalance
    }
    
    /// Request restore from mint (NUT-09)
    internal func requestRestore(
        blindedMessages: [BlindedMessage],
        keysetID: String
    ) async throws -> [BlindSignature] {
        // Check if mint supports NUT-09
        guard currentMintInfo?.isNUTSupported("9") ?? false else {
            if let capabilityManager = capabilityManager {
                throw capabilityManager.unsupportedOperationError(
                    capability: .restore,
                    operation: "Restore proofs from backup"
                )
            } else {
                throw CashuError.unsupportedOperation("Restore functionality (NUT-09) is not supported by this mint")
            }
        }
        
        // Create restore service
        let restoreService = await RestoreSignatureService()
        
        // Request restore from mint
        let request = PostRestoreRequest(outputs: blindedMessages)
        let response = try await restoreService.restoreSignatures(request: request, mintURL: configuration.mintURL)
        
        // Extract signatures from response
        return response.signatures
    }
}
