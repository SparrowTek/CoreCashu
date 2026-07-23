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

    /// Validate a mnemonic phrase wrapped in ``SensitiveString``. The plaintext is only
    /// materialized inside the validator's `withString` scope.
    static func validateMnemonic(_ mnemonic: SensitiveString) async -> Bool {
        await mnemonic.withString { BIP39.validateMnemonic($0) }
    }

    /// Initialize wallet from secure store (restore existing wallet).
    /// The loaded mnemonic stays inside ``SensitiveString`` from secure-store load through
    /// wallet construction — the plaintext never lifts to a caller-visible `String`.
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

        guard batchSize > 0 else {
            throw CashuError.invalidAmount
        }

        let restoration = WalletRestoration(
            derivation: derivation,
            counterManager: keysetCounterManager
        )

        var totalRestoredBalance = 0
        var restorationErrors: [String: any Error] = [:]

        // Restore across ALL keysets the mint knows, active or not — long-lived funds sit
        // precisely under rotated-out keysets. `currentKeysetInfos` is populated from
        // /v1/keysets, which includes inactive entries.
        let keysetIDs = Array(currentKeysetInfos.keys)
        for keysetID in keysetIDs {
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

        // If every attempted keyset failed, surface the first error. Partial failures are
        // reported through `onProgress` and logged; the restore stays re-runnable because
        // already-stored proofs are skipped on the next pass.
        if !keysetIDs.isEmpty, restorationErrors.count == keysetIDs.count,
           let firstError = restorationErrors.values.first {
            throw firstError
        }

        if !restorationErrors.isEmpty {
            logger.warning("Restore completed with \(restorationErrors.count)/\(keysetIDs.count) keysets failing: \(restorationErrors.keys.sorted().joined(separator: ", "))")
        }

        return totalRestoredBalance
    }

    /// Get current keyset counters
    func getKeysetCounters() async throws -> [String: UInt32] {
        return try await keysetCounterManager.getAllCounters()
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
        var currentCounter = try await keysetCounterManager.getCounter(for: keysetID)
        let scanStartCounter = currentCounter
        var totalProofsFound = 0
        var unspentProofsFound = 0
        // Highest counter index the mint actually recognized — the basis for the final
        // counter value (never a batch-arithmetic estimate).
        var highestSignedCounter: UInt32?

        let mintKeys = try await restorationKeys(for: keysetID)

        // Snapshot of secrets already in storage so re-running a restore (e.g. after a
        // partial failure) skips proofs from earlier passes instead of throwing.
        var knownSecrets = Set(try await proofManager.getAllProofs().map { $0.secret })

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
            let response = try await requestRestore(
                blindedMessages: blindedMessages,
                keysetID: keysetID
            )

            if response.signatures.isEmpty {
                consecutiveEmptyBatches += 1
            } else {
                consecutiveEmptyBatches = 0

                // NUT-09: the mint echoes the subset of `outputs` it recognized, aligned
                // 1:1 with `signatures`. Each echoed output is matched back to its batch
                // position by B_ so every signature is unblinded with the blinding factor
                // and secret of the counter that actually produced it — positional pairing
                // corrupts every proof after the first gap.
                guard response.outputs.count == response.signatures.count else {
                    throw CashuError.invalidResponse
                }

                var batchIndexByB = [String: Int]()
                for (index, message) in blindedMessages.enumerated() {
                    batchIndexByB[message.B_] = index
                }

                var restoredProofs: [Proof] = []
                for (respIndex, signature) in response.signatures.enumerated() {
                    guard let batchIndex = batchIndexByB[response.outputs[respIndex].B_] else {
                        throw CashuError.invalidResponse
                    }

                    let counter = currentCounter + UInt32(batchIndex)
                    highestSignedCounter = max(highestSignedCounter ?? 0, counter)

                    let secret = try restoration.derivation.deriveSecret(
                        keysetID: keysetID,
                        counter: counter
                    )

                    guard let publicKeyHex = mintKeys[String(signature.amount)],
                          let publicKeyData = Data(hexString: publicKeyHex),
                          let mintPublicKey = try? P256K.KeyAgreement.PublicKey(dataRepresentation: publicKeyData, format: .compressed) else {
                        throw CashuError.keysetNotFound
                    }

                    let restored = try restoration.restoreProofs(
                        blindedSignatures: [signature],
                        blindingFactors: [blindingFactors[batchIndex]],
                        secrets: [secret],
                        keysetID: keysetID,
                        mintPublicKey: mintPublicKey
                    )
                    restoredProofs.append(contentsOf: restored)
                }

                // Check proof states
                let stateResult = try await checkProofStates(restoredProofs)

                // Keep only unspent proofs that aren't already in storage
                var unspentProofs: [Proof] = []
                for result in stateResult.results {
                    if result.stateInfo.state == .unspent, !knownSecrets.contains(result.proof.secret) {
                        unspentProofs.append(result.proof)
                        knownSecrets.insert(result.proof.secret)
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

        // The next usable counter is one past the highest index the mint signed. When the
        // scan found nothing, the counter stays where the scan started — it must never
        // move backwards or drift forward past unused indices.
        let finalCounter: UInt32
        if let highestSignedCounter {
            finalCounter = highestSignedCounter + 1
        } else {
            finalCounter = scanStartCounter
        }
        if finalCounter > scanStartCounter {
            try await keysetCounterManager.setCounter(for: keysetID, value: finalCounter)
        }

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

    /// Resolve the amount→pubkey map for a keyset, falling back to a per-keyset key fetch
    /// for keysets (typically inactive ones) that aren't in the wallet's active-key cache.
    private func restorationKeys(for keysetID: String) async throws -> [String: String] {
        if let keyset = currentKeysets[keysetID] {
            return keyset.keys
        }

        guard let keyExchangeService = keyExchangeService else {
            throw CashuError.walletNotInitialized
        }

        let response = try await keyExchangeService.getKeys(from: configuration.mintURL, keysetID: keysetID)
        guard let keyset = response.keysets.first(where: { $0.id == keysetID }) else {
            throw CashuError.keysetNotFound
        }
        return keyset.keys
    }

    /// Request restore from mint (NUT-09). Returns the full response — `outputs` is
    /// required to align each signature with the counter that produced it.
    internal func requestRestore(
        blindedMessages: [BlindedMessage],
        keysetID: String
    ) async throws -> PostRestoreResponse {
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
        let restoreService = await RestoreSignatureService(networking: networking)

        // Request restore from mint
        let request = PostRestoreRequest(outputs: blindedMessages)
        return try await restoreService.restoreSignatures(request: request, mintURL: configuration.mintURL)
    }
}
