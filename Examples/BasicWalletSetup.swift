/// # Basic Wallet Setup
///
/// This example demonstrates how to create and initialize a CoreCashu wallet
/// on different platforms.

import CoreCashu
import Foundation

// MARK: - Cross-Platform Wallet Setup

/// Create a basic wallet with in-memory storage (for testing/demos only)
func createTestWallet() async throws -> CashuWallet {
    let config = WalletConfiguration(
        mintURL: "https://testnut.cashu.space",
        unit: .sat
    )
    
    // In-memory storage - NOT for production use
    let wallet = await CashuWallet(configuration: config)
    
    // Initialize the wallet (fetches mint keysets)
    try await wallet.initialize()
    
    return wallet
}

// MARK: - Linux/Server Wallet Setup

/// Create a production wallet for Linux/server environments
func createLinuxWallet() async throws -> CashuWallet {
    // Use encrypted file storage
    let dataDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cashu-wallet")
    
    let secureStore = try FileSecureStore(
        directory: dataDirectory,
        password: "your-secure-password" // Consider using environment variable
    )
    
    let config = WalletConfiguration(
        mintURL: "https://mint.example.com",
        unit: .sat
    )
    
    let wallet = await CashuWallet(
        configuration: config,
        secureStore: secureStore
    )
    
    try await wallet.initialize()
    
    return wallet
}

// MARK: - Deterministic Wallet with Mnemonic

/// Create a wallet with mnemonic for backup/restore capability
func createDeterministicWallet() async throws -> CashuWallet {
    // Generate a new mnemonic (12 words by default)
    let mnemonic = try BIP39.generateMnemonic(strength: .words12)
    print("Save these words securely: \(mnemonic)")
    
    let config = WalletConfiguration(
        mintURL: "https://mint.example.com",
        unit: .sat
    )
    
    // Create wallet with mnemonic for deterministic secrets
    let wallet = try await CashuWallet(
        configuration: config,
        mnemonic: mnemonic
    )
    
    try await wallet.initialize()
    
    return wallet
}

/// Restore a wallet from an existing mnemonic
func restoreWalletFromMnemonic(mnemonic: String) async throws -> CashuWallet {
    // Validate the mnemonic first
    guard BIP39.validateMnemonic(mnemonic) else {
        throw CashuError.invalidMnemonic
    }
    
    let config = WalletConfiguration(
        mintURL: "https://mint.example.com",
        unit: .sat
    )
    
    let wallet = try await CashuWallet(
        configuration: config,
        mnemonic: mnemonic
    )
    
    try await wallet.initialize()
    
    // Restore proofs from the mint
    let restoredBalance = try await wallet.restoreFromSeed { progress in
        print("Restore progress: \(progress)")
    }
    
    print("Restored balance: \(restoredBalance) sats")
    
    return wallet
}

// MARK: - Wallet with Custom Logger

/// Create a wallet with custom logging for debugging
func createWalletWithLogging() async throws -> CashuWallet {
    let config = WalletConfiguration(
        mintURL: "https://mint.example.com",
        unit: .sat
    )
    
    // Use console logger for debugging
    let logger = ConsoleLogger()
    logger.setMinimumLevel(.debug)
    
    let wallet = await CashuWallet(
        configuration: config,
        logger: logger
    )
    
    try await wallet.initialize()
    
    return wallet
}

// MARK: - Multi-Mint Wallet Management

/// Example of managing wallets for multiple mints
actor WalletManager {
    private var wallets: [URL: CashuWallet] = [:]
    
    /// Get or create a wallet for a specific mint
    func wallet(for mintURL: URL) async throws -> CashuWallet {
        if let existing = wallets[mintURL] {
            return existing
        }
        
        let config = WalletConfiguration(
            mintURL: mintURL.absoluteString,
            unit: .sat
        )
        
        let wallet = await CashuWallet(configuration: config)
        try await wallet.initialize()
        
        wallets[mintURL] = wallet
        return wallet
    }
    
    /// Get total balance across all wallets
    func totalBalance() async throws -> Int {
        var total = 0
        for wallet in wallets.values {
            total += try await wallet.balance
        }
        return total
    }
}
