//
//  MeltChangeAndCounterTests.swift
//  CoreCashu
//
//  Regression coverage for two fund-safety fixes:
//  1. melt() must send NUT-08 blank outputs and credit the returned change — before the
//     fix, input overshoot was silently donated to the mint on every non-exact melt.
//  2. NUT-13 keyset counters must persist through the injected KeysetCounterStorage —
//     before the fix the storage parameter was ignored and every relaunch re-derived
//     the same deterministic secrets.
//

import Foundation
import Testing
@testable import CoreCashu

@Suite("Melt change and counter persistence")
struct MeltChangeAndCounterTests {

    private static let mintURL = "https://mock.mint"

    @Test("Melting with input overshoot returns the difference as change")
    func meltOvershootReturnsChange() async throws {
        let mint = try await MockMint()
        let configuration = try WalletConfiguration(mintURL: Self.mintURL)
        let wallet = await CashuWallet(
            configuration: configuration,
            secureStore: InMemorySecureStore(),
            networking: mint.networking
        )
        try await wallet.initialize()

        // Mint a single 64-sat proof, then melt a 10-sat invoice. The only possible
        // input is the 64-sat proof, so the mint owes 54 back through blank outputs.
        let quote = try await wallet.requestMintQuote(amount: 64)
        _ = try await wallet.mint(quoteID: quote.quote, amount: 64)
        #expect(try await wallet.balance == 64)

        let result = try await wallet.melt(paymentRequest: "lnbc10q1zsay")
        #expect(result.state == .paid)
        #expect(result.changeProofs.reduce(0) { $0 + $1.amount } == 54)

        // The change must be spendable balance, not a donation to the mint.
        #expect(try await wallet.balance == 54)
    }

    @Test("Keyset counters persist through injected storage across wallet instances")
    func countersPersistAcrossWallets() async throws {
        let mint = try await MockMint()
        let configuration = try WalletConfiguration(mintURL: Self.mintURL)
        let counterStorage = InMemoryKeysetCounterStorage()
        let mnemonic = try BIP39.generateMnemonic()

        let first = try await CashuWallet(
            configuration: configuration,
            mnemonic: mnemonic,
            counterStorage: counterStorage,
            secureStore: InMemorySecureStore(),
            networking: mint.networking
        )
        try await first.initialize()

        let quote = try await first.requestMintQuote(amount: 16)
        _ = try await first.mint(quoteID: quote.quote, amount: 16)

        let countersAfterMint = try await first.getKeysetCounters()
        let usedKeyset = try #require(countersAfterMint.first(where: { $0.value > 0 }))

        // A fresh wallet over the SAME storage must resume from the persisted counter,
        // not restart at zero (which would re-derive already-used secrets).
        let second = try await CashuWallet(
            configuration: configuration,
            mnemonic: mnemonic,
            counterStorage: counterStorage,
            secureStore: InMemorySecureStore(),
            networking: mint.networking
        )
        try await second.initialize()

        let resumed = try await second.getKeysetCounters()
        #expect(resumed[usedKeyset.key] == usedKeyset.value)

        // And the second wallet can mint without "output already signed" collisions.
        let quote2 = try await second.requestMintQuote(amount: 8)
        _ = try await second.mint(quoteID: quote2.quote, amount: 8)
        #expect(try await second.balance == 8)
    }
}
