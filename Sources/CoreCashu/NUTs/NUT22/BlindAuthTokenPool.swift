//
//  BlindAuthTokenPool.swift
//  CoreCashu
//
//  Phase 8.2 follow-up (2026-04-29) — BAT pool semantics for NUT-22. Pre-mints a configurable
//  number of Blind Authentication Tokens, draws one per protected request via the
//  `Blind-auth:` header, and refreshes asynchronously when the depth drops below a watermark.
//

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// In-memory BAT pool backing the `Blind-auth:` header consumption flow.
///
/// The pool wraps a list of unspent BATs (each one a NUT-22 access-token `Proof`) and exposes
/// a single `next()` operation that returns one and removes it from the pool. Callers attach
/// the returned token's `secret` string as the `Blind-auth:` header on the protected request.
///
/// Refresh policy: when `count` drops below `lowWatermark` and a `refresh` closure is set, the
/// pool kicks off an async refresh via the closure. The refresh closure is responsible for
/// minting fresh BATs and adding them via `add(_:)`. Refreshes are mutually exclusive — a
/// pending refresh blocks subsequent triggers.
public actor BlindAuthTokenPool {
    public let lowWatermark: Int
    public let target: Int

    private var tokens: [Proof] = []
    private var refreshing: Bool = false
    private var refreshClosure: (@Sendable (BlindAuthTokenPool) async throws -> Void)?

    public init(lowWatermark: Int = 8, target: Int = 32) {
        precondition(lowWatermark >= 0)
        precondition(target >= lowWatermark)
        self.lowWatermark = lowWatermark
        self.target = target
    }

    /// Configure the refresh closure. The pool calls this when depth drops below
    /// `lowWatermark`. The closure should obtain fresh BATs (e.g., via
    /// `AccessTokenService.requestAccessTokens`) and call `add(_:)` to deposit them.
    public func setRefreshHandler(_ handler: @escaping @Sendable (BlindAuthTokenPool) async throws -> Void) {
        refreshClosure = handler
    }

    /// Add tokens to the pool. Used by the refresh handler and during initial seeding.
    public func add(_ newTokens: [Proof]) {
        tokens.append(contentsOf: newTokens)
    }

    /// Current pool depth.
    public var count: Int { tokens.count }

    /// Returns whether a refresh is in flight.
    public var isRefreshing: Bool { refreshing }

    /// Draw a single BAT for a protected request. Removes the token from the pool. Returns
    /// `nil` when the pool is empty; callers should treat that as "auth unavailable, refresh
    /// pending or absent" and handle accordingly.
    ///
    /// Triggers an async refresh when the post-draw depth is below `lowWatermark`. The
    /// refresh runs on a detached `Task` so the caller doesn't pay its latency.
    public func next() async -> Proof? {
        guard !tokens.isEmpty else {
            triggerRefreshIfNeeded()
            return nil
        }
        let token = tokens.removeFirst()
        if tokens.count < lowWatermark {
            triggerRefreshIfNeeded()
        }
        return token
    }

    /// Drain the pool. Used at shutdown or when invalidating the auth context.
    public func drain() -> [Proof] {
        let drained = tokens
        tokens.removeAll()
        return drained
    }

    private func triggerRefreshIfNeeded() {
        guard !refreshing, let closure = refreshClosure else { return }
        refreshing = true
        Task {
            defer { Task { await self.markRefreshComplete() } }
            do {
                try await closure(self)
            } catch {
                // Swallow — caller surfaces auth failures via the next request that lacks a
                // BAT. Logging is the consumer's responsibility (the closure can do it).
            }
        }
    }

    private func markRefreshComplete() {
        refreshing = false
    }
}

/// Convenience: build a pool whose refresh handler calls back into an `AccessTokenService` to
/// pre-mint the next batch.
public extension BlindAuthTokenPool {
    /// Create a pool backed by `service` for `mintURL` + `quoteId` + `keysetId`. The refresh
    /// handler issues `target - count` BATs each time it fires, capped at `target`.
    static func backed(
        by service: AccessTokenService,
        mintURL: String,
        quoteId: String,
        keysetId: String,
        lowWatermark: Int = 8,
        target: Int = 32
    ) async -> BlindAuthTokenPool {
        let pool = BlindAuthTokenPool(lowWatermark: lowWatermark, target: target)
        await pool.setRefreshHandler { pool in
            let needed = await max(target - pool.count, 0)
            guard needed > 0 else { return }
            let fresh = try await service.requestAccessTokens(
                mintURL: mintURL,
                quoteId: quoteId,
                amount: needed,
                keysetId: keysetId
            )
            await pool.add(fresh)
        }
        return pool
    }
}

/// Helper for attaching the `Blind-auth:` header to a `URLRequest` from a BAT.
public enum BlindAuthHeader {
    /// Apply the `Blind-auth: <secret>` header to a `URLRequest` for a single protected
    /// request. Per NUT-22, one BAT is consumed per request; the caller is responsible for
    /// drawing one from a `BlindAuthTokenPool` and not reusing it.
    public static func apply(to request: inout URLRequest, token: Proof) {
        request.setValue(token.secret, forHTTPHeaderField: NUT22Endpoints.blindAuthHeader)
    }
}
