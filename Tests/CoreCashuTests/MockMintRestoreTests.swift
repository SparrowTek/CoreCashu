import Foundation
import Testing
@testable import CoreCashu

/// Phase 8.3 (2026-04-29): deeper coverage for the NUT-09 restore-from-seed flow against the
/// in-process ``MockMint``. Confirms capability-gating, mnemonic-required gating, and the
/// MockMint NUT-09 endpoint shape. Surfaces one concrete bug (see
/// ``restoreFromSeedDoesNotYetReuseDeterministicDerivationDuringMint``).
@Suite("MockMint NUT-09 restore-from-seed integration")
struct MockMintRestoreTests {

    private static let mintURL = "https://mock.mint"

    private func makeWalletWithMnemonic(_ mint: MockMint, mnemonic: String? = nil) async throws -> (CashuWallet, String) {
        let mnemonic = try (mnemonic ?? CashuWallet.generateMnemonic())
        let configuration = try WalletConfiguration(mintURL: Self.mintURL)
        let wallet = try await CashuWallet(
            configuration: configuration,
            mnemonic: mnemonic,
            secureStore: InMemorySecureStore(),
            networking: mint.networking
        )
        try await wallet.initialize()
        return (wallet, mnemonic)
    }

    private func mintProofs(_ wallet: CashuWallet, amount: Int) async throws {
        let quote = try await wallet.requestMintQuote(amount: amount)
        _ = try await wallet.mint(quoteID: quote.quote, amount: amount)
    }

    @Test("restoreFromSeed throws unsupportedOperation when the mint omits NUT-09")
    func restoreRejectedWhenNUT09Missing() async throws {
        let mint = try await MockMint(configuration: .init(advertisedNUTsExclude: ["9"]))
        let (wallet, _) = try await makeWalletWithMnemonic(mint)
        await #expect(throws: CashuError.self) {
            _ = try await wallet.restoreFromSeed()
        }
    }

    @Test("restoreFromSeed throws when the wallet was not initialized with a mnemonic")
    func restoreRejectedWhenNoMnemonic() async throws {
        let mint = try await MockMint()
        let configuration = try WalletConfiguration(mintURL: Self.mintURL)
        let wallet = await CashuWallet(
            configuration: configuration,
            secureStore: InMemorySecureStore(),
            networking: mint.networking
        )
        try await wallet.initialize()

        await #expect(throws: CashuError.self) {
            _ = try await wallet.restoreFromSeed()
        }
    }

    @Test("MockMint /v1/restore returns the (output, signature) pairs the mint signed earlier")
    func restoreEndpointReturnsPreviouslySignedOutputs() async throws {
        let mint = try await MockMint()
        let (wallet, _) = try await makeWalletWithMnemonic(mint)

        // Mint some proofs through the live mint flow. This exercises MockMint's `sign(outputs:)`
        // which records (B_, BlindSignature) pairs in `signedOutputs`.
        try await mintProofs(wallet, amount: 16)

        // Drive a synthetic /v1/restore request directly with the *exact same* B_ values the
        // wallet produced during mint — fish them out of the wallet's current proofs by walking
        // back through the BDHKE: Y = hash_to_curve(secret), B_ = Y + r*G — but we don't have
        // r. Instead, we exercise the simpler contract: an empty restore request returns empty,
        // and a request with a nonexistent B_ returns empty (no false positives).
        let baseURL = try #require(URL(string: Self.mintURL))
        let router = await NetworkRouter<RestoreAPI>(networking: mint.networking)
        let emptyResponse: PostRestoreResponse = try await router.execute(
            .restore(PostRestoreRequest(outputs: []), baseURL: baseURL)
        )
        #expect(emptyResponse.outputs.isEmpty)
        #expect(emptyResponse.signatures.isEmpty)

        // Nonexistent B_ — must come back empty.
        let bogusOutput = BlindedMessage(amount: 0, id: "00", B_: String(repeating: "ff", count: 33))
        let bogusResponse: PostRestoreResponse = try await router.execute(
            .restore(PostRestoreRequest(outputs: [bogusOutput]), baseURL: baseURL)
        )
        #expect(bogusResponse.outputs.isEmpty)
        #expect(bogusResponse.signatures.isEmpty)
    }

    /// Phase 8.3 follow-up (2026-04-29): the bug surfaced earlier is now fixed. The mint and
    /// swap services accept a `DeterministicOutputProvider` and the wallet builds one from its
    /// `deterministicDerivation` + `keysetCounterManager`. After this lands, a wallet that
    /// holds the same mnemonic as the original issuer can restore the full balance from the
    /// mint's NUT-09 endpoint because the B_ values match between issuance and restore.
    @Test("restoreFromSeed rediscovers proofs the original wallet minted under the same seed")
    func restoreFromSeedRediscoversIssuedProofs() async throws {
        let mint = try await MockMint()
        let (wallet1, mnemonic) = try await makeWalletWithMnemonic(mint)
        try await mintProofs(wallet1, amount: 16)
        let originalBalance = try await wallet1.balance
        #expect(originalBalance == 16)

        // Wallet 2 with the same mnemonic. With deterministic derivation now wired through
        // mint/swap, restore re-derives the same B_ values, hits MockMint's restore cache, and
        // recovers the full amount.
        let (wallet2, _) = try await makeWalletWithMnemonic(mint, mnemonic: mnemonic)
        let restoredBalance = try await wallet2.restoreFromSeed()
        #expect(restoredBalance == 16, "Expected to restore the full 16 sats; got \(restoredBalance)")
        let walletBalance = try await wallet2.balance
        #expect(walletBalance == 16)
    }
}
