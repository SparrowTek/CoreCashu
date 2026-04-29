//
//  DeterministicOutputProvider.swift
//  CoreCashu
//
//  Phase 8.3 follow-up (2026-04-29) — wires the wallet's NUT-13 deterministic derivation into
//  mint/swap output generation so `restoreFromSeed` can rediscover proofs the wallet itself
//  issued. Without this, the issuance path used random secrets and the B_ values stored at the
//  mint never matched the deterministic B_ values produced by restore.
//

import Foundation

/// Derives the (secret, blinding factor) pair for a given keyset+counter pair. Wraps a
/// ``DeterministicSecretDerivation`` and a ``KeysetCounterManager`` so callers don't have to
/// manage counter state themselves.
///
/// Two-step usage: ``reserve(count:for:)`` advances the counter by `count` and returns the
/// starting counter; then call ``derive(keysetID:counter:)`` for each output index.
public struct DeterministicOutputProvider: Sendable {
    public let derivation: DeterministicSecretDerivation
    public let counterManager: KeysetCounterManager

    public init(
        derivation: DeterministicSecretDerivation,
        counterManager: KeysetCounterManager
    ) {
        self.derivation = derivation
        self.counterManager = counterManager
    }

    /// Reserve a contiguous block of `count` counters for `keysetID` and advance the manager.
    /// Returns the **starting** counter for the block; the caller fills counters
    /// `start..<start+count`.
    public func reserve(count: Int, for keysetID: String) async -> UInt32 {
        let start = await counterManager.getCounter(for: keysetID)
        await counterManager.setCounter(for: keysetID, value: start + UInt32(count))
        return start
    }

    /// Derive `(secret, blindingFactor)` at the given counter. Pure function — does not
    /// advance any state.
    public func derive(keysetID: String, counter: UInt32) throws -> (secret: String, blindingFactor: Data) {
        let secret = try derivation.deriveSecret(keysetID: keysetID, counter: counter)
        let blindingFactor = try derivation.deriveBlindingFactor(keysetID: keysetID, counter: counter)
        return (secret, blindingFactor)
    }

    /// Convenience: build N `WalletBlindingData` instances for `keysetID`, advancing the
    /// counter by N. Used by mint/swap services when the wallet has a deterministic source.
    public func makeBlindingData(count: Int, for keysetID: String) async throws -> [WalletBlindingData] {
        let start = await reserve(count: count, for: keysetID)
        var result: [WalletBlindingData] = []
        result.reserveCapacity(count)
        for offset in 0..<count {
            let (secret, blindingFactor) = try derive(keysetID: keysetID, counter: start + UInt32(offset))
            result.append(try WalletBlindingData(secret: secret, blindingFactor: blindingFactor))
        }
        return result
    }
}
