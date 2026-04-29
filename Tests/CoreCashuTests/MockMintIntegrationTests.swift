import Foundation
import Testing
@testable import CoreCashu

/// End-to-end wallet flow against the in-process ``MockMint``.
///
/// These tests deliberately go through the public ``CashuWallet`` API — initialize/
/// requestMintQuote/mint/send/receive/melt/checkProofStates — rather than poking individual
/// services. That's the surface the rest of Phase 6 will rely on for both the smoke-test
/// replacements and the live-mint exercises of P2PK and HTLC.
@Suite("MockMint wallet integration")
struct MockMintIntegrationTests {

    private static let mintURL = "https://mock.mint"

    private func makeWallet(_ mint: MockMint) async throws -> CashuWallet {
        let configuration = try WalletConfiguration(mintURL: Self.mintURL)
        let wallet = await CashuWallet(
            configuration: configuration,
            secureStore: InMemorySecureStore(),
            networking: mint.networking
        )
        try await wallet.initialize()
        return wallet
    }

    // MARK: - Golden path

    @Test("Initialize, mint, swap-to-send, receive, melt round-trips")
    func goldenPath() async throws {
        let mint = try await MockMint()
        let wallet = try await makeWallet(mint)
        let ready = await wallet.isReady
        #expect(ready)

        // Mint 64 sat.
        let quote = try await wallet.requestMintQuote(amount: 64)
        #expect(quote.unit == "sat")
        let mintResult: MintResult
        do {
            mintResult = try await wallet.mint(quoteID: quote.quote, amount: 64)
        } catch {
            Issue.record("mint failed: \(error)")
            throw error
        }
        #expect(mintResult.totalAmount == 64)
        #expect(mintResult.newProofs.reduce(0) { $0 + $1.amount } == 64)

        let balanceAfterMint = try await wallet.balance
        #expect(balanceAfterMint == 64)

        // Send 10 sat — exercises the swap-to-send path with change.
        let token: CashuToken
        do {
            token = try await wallet.send(amount: 10, memo: "lunch")
        } catch {
            Issue.record("send failed: \(error)")
            throw error
        }
        let sentTotal = token.token.flatMap { $0.proofs }.reduce(0) { $0 + $1.amount }
        #expect(sentTotal == 10)

        let balanceAfterSend = try await wallet.balance
        #expect(balanceAfterSend == 64 - 10)

        // Receive into a separate wallet (same mint).
        let receiver = try await makeWallet(mint)
        let receivedProofs: [Proof]
        do {
            receivedProofs = try await receiver.receive(token: token)
        } catch {
            Issue.record("receive failed: \(error)")
            throw error
        }
        #expect(receivedProofs.reduce(0) { $0 + $1.amount } == 10)
        let receiverBalance = try await receiver.balance
        #expect(receiverBalance == 10)

        // The sender's proofs that were sent must now be marked as spent at the mint.
        let proofsInToken = token.token.flatMap { $0.proofs }
        for proof in proofsInToken {
            let spent = try await mint.isProofSpent(proof)
            #expect(spent, "Proof should be spent on the mint after recipient swapped it")
        }

        // Receiver melts the received balance — exercises the melt path. The invoice has to be
        // valid Bech32 (the wallet's NUTValidation rejects "o" and other excluded chars).
        let meltInvoice = "lnbc10q1zsay"
        let meltResult: MeltResult
        do {
            meltResult = try await receiver.melt(paymentRequest: meltInvoice)
        } catch {
            Issue.record("melt failed: \(error)")
            throw error
        }
        #expect(meltResult.state == .paid)
        let receiverBalanceAfterMelt = try await receiver.balance
        #expect(receiverBalanceAfterMelt == 0)
        let meltCalls = await mint.meltCount()
        #expect(meltCalls == 1)
    }

    // MARK: - Negative cases

    @Test("Mint with NUT-04 disabled is rejected at initialization")
    func mintDisabled() async throws {
        let mint = try await MockMint(configuration: .init(mintEnabled: false))
        let configuration = try WalletConfiguration(mintURL: Self.mintURL)
        let wallet = await CashuWallet(
            configuration: configuration,
            secureStore: InMemorySecureStore(),
            networking: mint.networking
        )
        await #expect(throws: CashuError.self) {
            try await wallet.initialize()
        }
    }

    @Test("Double-spend through swap is rejected by the mint")
    func doubleSpendRejected() async throws {
        let mint = try await MockMint()
        let wallet = try await makeWallet(mint)
        let recipient = try await makeWallet(mint)

        let quote = try await wallet.requestMintQuote(amount: 16)
        _ = try await wallet.mint(quoteID: quote.quote, amount: 16)

        // First send and receive consumes the proofs at the mint.
        let token = try await wallet.send(amount: 4)
        _ = try await recipient.receive(token: token)

        // Re-present the same token: the mint must reject because the proofs are already spent.
        await #expect(throws: (any Error).self) {
            _ = try await recipient.receive(token: token)
        }
    }

    @Test("checkProofStates round-trips and reports SPENT after a swap")
    func checkProofStatesAfterSwap() async throws {
        let mint = try await MockMint()
        let wallet = try await makeWallet(mint)

        let quote = try await wallet.requestMintQuote(amount: 8)
        let result = try await wallet.mint(quoteID: quote.quote, amount: 8)

        // Initially, all freshly-minted proofs report UNSPENT.
        let beforeSwap = try await wallet.checkProofStates(result.newProofs)
        #expect(beforeSwap.results.allSatisfy { $0.state == .unspent })

        // After a self-swap (send-to-self semantics), the original proofs flip to SPENT.
        let token = try await wallet.send(amount: 8)
        let spentProofs = token.token.flatMap { $0.proofs }

        let stateOfSpent = try await wallet.checkProofStates(result.newProofs)
        // result.newProofs and spentProofs share secrets only in the trivial case; what we know
        // for sure is that the wallet's *original* proofs are gone, so the mint should know they
        // were consumed via swap.
        let resolvedToSpent = stateOfSpent.results.filter { $0.state == .spent }.count
        #expect(resolvedToSpent == result.newProofs.count, "Expected all original proofs to be spent on the mint")

        // The brand-new send proofs are still UNSPENT until they're swapped again.
        let stateOfNewToken = try await wallet.checkProofStates(spentProofs)
        #expect(stateOfNewToken.results.allSatisfy { $0.state == .unspent })
    }

    @Test("Wallet defaults to keyset id derived from the mint's public keys")
    func keysetIDPropagates() async throws {
        let mint = try await MockMint()
        let wallet = try await makeWallet(mint)

        let keysets = await wallet.keysets
        #expect(keysets.count == 1)
        let advertised = keysets.values.first
        #expect(advertised?.id == mint.keysetID)
    }

    @Test("MockMint serves /v1/info and the wallet recognises basic NUTs")
    func mintInfoRoundTrip() async throws {
        let mint = try await MockMint(configuration: .init(name: "RoundTripMint"))
        let wallet = try await makeWallet(mint)

        let info = await wallet.mintInfo
        #expect(info?.name == "RoundTripMint")
        #expect(info?.supportsBasicOperations() == true)
        // NUT-04/NUT-05 must surface as supported with the configured method/unit.
        let nut04 = info?.getNUT04Settings()
        #expect(nut04?.disabled == false)
        #expect(nut04?.isSupported(method: "bolt11", unit: "sat") == true)
    }
}
