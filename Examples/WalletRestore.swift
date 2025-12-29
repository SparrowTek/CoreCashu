/// # Wallet Restoration
///
/// This example demonstrates how to restore a wallet from a mnemonic seed phrase.

import CoreCashu
import Foundation

// MARK: - Generating and Saving Mnemonic

/// Generate a new mnemonic for a fresh wallet
func generateNewMnemonic() throws -> String {
    // Generate a 12-word mnemonic (128 bits of entropy)
    let mnemonic = try BIP39.generateMnemonic(strength: .words12)
    
    print("Generated mnemonic (12 words):")
    print(mnemonic)
    print("\nIMPORTANT: Save these words securely. They can restore your wallet.")
    
    return mnemonic
}

/// Generate a stronger 24-word mnemonic
func generate24WordMnemonic() throws -> String {
    let mnemonic = try BIP39.generateMnemonic(strength: .words24)
    
    print("Generated mnemonic (24 words):")
    print(mnemonic)
    
    return mnemonic
}

// MARK: - Validating Mnemonic

/// Validate a mnemonic before using it
func validateMnemonic(_ mnemonic: String) -> Bool {
    let isValid = BIP39.validateMnemonic(mnemonic)
    
    if isValid {
        print("Mnemonic is valid")
        
        // Count words
        let words = mnemonic.split(separator: " ")
        print("Word count: \(words.count)")
        
    } else {
        print("Mnemonic is INVALID")
        print("Check that:")
        print("  - All words are from the BIP39 wordlist")
        print("  - Word count is 12, 15, 18, 21, or 24")
        print("  - Checksum is correct")
    }
    
    return isValid
}

// MARK: - Restoring Wallet

/// Restore a wallet from mnemonic
func restoreWallet(mnemonic: String, mintURL: String) async throws -> CashuWallet {
    // Validate first
    guard BIP39.validateMnemonic(mnemonic) else {
        throw CashuError.invalidMnemonic
    }
    
    let config = WalletConfiguration(
        mintURL: mintURL,
        unit: .sat
    )
    
    // Create wallet with mnemonic
    let wallet = try await CashuWallet(
        configuration: config,
        mnemonic: mnemonic
    )
    
    try await wallet.initialize()
    
    print("Wallet initialized with mnemonic")
    print("Starting restoration from mint...")
    
    // Restore proofs from the mint (NUT-09, NUT-13)
    let restoredBalance = try await wallet.restoreFromSeed { progress in
        print("Restoration progress: batch \(progress)")
    }
    
    print("Restoration complete!")
    print("Restored balance: \(restoredBalance) sats")
    
    return wallet
}

// MARK: - Restore with Progress

/// Restore with detailed progress tracking
func restoreWithProgress(
    wallet: CashuWallet,
    batchSize: Int = 100
) async throws -> Int {
    print("Starting wallet restoration...")
    print("Batch size: \(batchSize)")
    
    var totalRestored = 0
    var batchCount = 0
    
    let balance = try await wallet.restoreFromSeed(batchSize: batchSize) { progress in
        batchCount += 1
        print("Processing batch \(batchCount)...")
    }
    
    print("\nRestoration complete")
    print("Total batches processed: \(batchCount)")
    print("Restored balance: \(balance) sats")
    
    return balance
}

// MARK: - Checking Restore Status

/// Check what proofs exist for a keyset
func checkExistingProofs(wallet: CashuWallet) async throws {
    let proofs = try await wallet.getAvailableProofs()
    
    print("Available proofs: \(proofs.count)")
    
    // Group by keyset
    let byKeyset = Dictionary(grouping: proofs) { $0.id }
    
    for (keysetId, keysetProofs) in byKeyset {
        let total = keysetProofs.reduce(0) { $0 + $1.amount }
        print("  Keyset \(keysetId): \(keysetProofs.count) proofs, \(total) sats")
    }
}

// MARK: - Mnemonic Backup Helpers

/// Display mnemonic for backup
func displayMnemonicForBackup(wallet: CashuWallet) async throws {
    // Note: In production, implement secure display with user verification
    
    guard let mnemonic = try await wallet.getMnemonic() else {
        print("No mnemonic available - wallet may not be deterministic")
        return
    }
    
    let words = mnemonic.split(separator: " ")
    
    print("\n=== WALLET BACKUP ===")
    print("Write down these words in order:\n")
    
    for (index, word) in words.enumerated() {
        print("\(index + 1). \(word)")
    }
    
    print("\nTotal: \(words.count) words")
    print("===================\n")
}

// MARK: - Seed Derivation

/// Understand the derivation path
func explainDerivation() {
    print("Cashu Deterministic Secrets (NUT-13)")
    print("====================================")
    print("")
    print("Derivation path: m/129372'/0'/{keyset_id}'/{counter}'")
    print("")
    print("Where:")
    print("  - 129372' is the Cashu purpose (hardened)")
    print("  - 0' is reserved for future use")
    print("  - keyset_id' is derived from the mint's keyset")
    print("  - counter' increments for each new proof")
    print("")
    print("This allows deterministic recreation of:")
    print("  - Secret values for blinded messages")
    print("  - Blinding factors (r values)")
    print("")
    print("To restore, the wallet re-derives secrets and checks")
    print("which have corresponding proofs on the mint.")
}

// MARK: - Multi-Mint Restoration

/// Restore wallet for multiple mints
func restoreMultipleMints(
    mnemonic: String,
    mintURLs: [String]
) async throws {
    guard BIP39.validateMnemonic(mnemonic) else {
        throw CashuError.invalidMnemonic
    }
    
    var totalBalance = 0
    
    for mintURL in mintURLs {
        print("\nRestoring from: \(mintURL)")
        
        let config = WalletConfiguration(mintURL: mintURL, unit: .sat)
        let wallet = try await CashuWallet(
            configuration: config,
            mnemonic: mnemonic
        )
        
        try await wallet.initialize()
        
        do {
            let balance = try await wallet.restoreFromSeed { _ in }
            print("  Restored: \(balance) sats")
            totalBalance += balance
        } catch {
            print("  Failed: \(error.localizedDescription)")
        }
    }
    
    print("\n======================")
    print("Total restored: \(totalBalance) sats")
}
