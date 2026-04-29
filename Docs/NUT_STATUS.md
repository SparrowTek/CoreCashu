# NUT Status Matrix

**Last updated:** 2026-04-29 (Phase 7 of `/opus47.md`)

This document tracks CoreCashu's implementation status against upstream
[`cashubtc/nuts`](https://github.com/cashubtc/nuts). The local snapshot in
`/claude/Nuts/` is a frozen copy; this doc is the truth source for what
CoreCashu supports.

**Status legend:**
- ✅ **Implemented** — code present, exercised by tests, advertised in
  `MintFeatureCapabilities` (or planned to be in Phase 7).
- 🟡 **Partial** — types/some logic present, but high-level wallet API
  incomplete or no spec-vector tests yet.
- 🔧 **Needs work** — implemented but with known correctness or scope gaps
  that block production advertising.
- ❌ **Not implemented** — no source file, or stub only.
- N/A — not applicable to a wallet (mint-only spec).

**Vector tests:** "✅ Pass" means a test in `Tests/CoreCashuTests/` exercises
the official spec vectors (where they exist). "—" means no spec vectors
exist or are not yet wired in.

## Core Protocol (NUT-00 through NUT-08)

| NUT | Title | Implemented | Vectors | Public API | Capability flag | Notes |
|---:|------|:----:|:----:|:----:|:----:|------|
| 00 | Notation, Terminology, Types | ✅ | ✅ Pass | ✅ | n/a | V3 (JSON) and V4 (CBOR) token codecs both present. |
| 01 | Mint public key exchange | ✅ | — | ✅ | n/a | |
| 02 | Keysets and keyset IDs | ✅ | ✅ Pass | ✅ | n/a | |
| 03 | Swap tokens | ✅ | — | ✅ | n/a | |
| 04 | Mint tokens (BOLT11) | ✅ | — | ✅ | n/a | |
| 05 | Melt tokens (BOLT11) | ✅ | — | ✅ | n/a | |
| 06 | Mint information | ✅ | — | ✅ | n/a | |
| 07 | Token state check | ✅ | — | ✅ | flag | |
| 08 | Lightning fee return | ✅ | — | ✅ | flag | |

## Optional NUTs (NUT-09 through NUT-29)

| NUT | Title | Implemented | Vectors | Public API | Capability flag | Notes |
|---:|------|:----:|:----:|:----:|:----:|------|
| 09 | Wallet restore from seed | 🟡 | — | partial | flag | Basic restore flow present; deeper recovery scenarios not exercised. |
| 10 | Spending conditions (well-known secret) | ✅ | ✅ Pass | ✅ | flag | Phase 4 wired the schema through `SwapService.prepareSwapToSend(targetSecretFactory:)` so locked outputs can be minted via the public wallet API. |
| 11 | P2PK | ✅ | ✅ Pass | ✅ | flag | **Phase 2.1 fixed the consensus bug** (Curve25519 → secp256k1 BIP340 Schnorr) and **Phase 4.A added the high-level wallet API** — `CashuWallet.sendLocked(amount:to:locktime:refundPubkeys:requiredSigs:additionalPubkeys:signatureFlag:memo:)` and `CashuWallet.unlockP2PK(token:privateKey:)`. Multisig signature accounting credits each distinct signer at most once; duplicate pubkeys rejected at construction. The spec's official "valid signature" vector (`60f3c9b766770b...`) now verifies under our Schnorr path — see `NUT11Tests`. |
| 12 | DLEQ proofs | ✅ | ✅ Pass | ✅ | flag | |
| 13 | Deterministic secrets (BIP39/BIP32) | ✅ | ✅ Pass | ✅ | n/a | |
| 14 | HTLC | ✅ | — | ✅ | flag | **Phase 4.C rewrote `HTLCOperations.swift`** to plumb the HTLC secret through swap (was generating a secret then discarding it). `createHTLC` now produces actually-locked outputs via the same `targetSecretFactory` path used by NUT-11. `redeemHTLC` attaches a real `HTLCWitness` per locked proof and submits a swap. `refundHTLC` signs each proof's secret with BIP340 Schnorr (was ECDSA — wrong curve) and submits with a refund-form witness. Live-mint integration tests (`HTLCIntegrationTests`) remain `.disabled` until Phase 6's mock mint lands. |
| 15 | Multi-path payments | 🟡 | — | partial | flag-off | **Post-1.0 by Phase 8.4 decision (2026-04-29).** MPP type definitions and primitives present in `Sources/CoreCashu/NUTs/NUT15/`; routing/pathfinding incomplete. The high-level wallet API (`sendMultiPath`, `combineMultiPath`, `receiveMultiPath`, `checkMPPStatus`) is gated behind `requireCapability(.mpp, ...)` and will throw `CashuError.unsupportedOperation` on every mint until the routing layer ships. Triggers reconsideration: a concrete v1 user with multi-mint requirements. |
| 16 | Animated QR codes | ✅ (data layer) | — | data-layer types only | flag | **Phase 8.5 decision (2026-04-29):** the data-layer logic (frame chunking, UR protocol handling) lives in `Sources/CoreCashu/NUTs/NUT16.swift` and only depends on `Foundation` — appropriate for a cross-platform package. The *rendering* layer (`UIImage` / `CIFilter` for static QR; frame-timing for animated QR) is the consumer's responsibility — typically a SwiftUI view in CashuKit or the app. CoreCashu does not ship a renderer. |
| 17 | WebSocket subscriptions | 🟡 | — | partial | flag | `RobustWebSocketClient`, `ReconnectionStrategy` present. Apple-platform only until cross-platform WS lands (Phase 3). |
| 18 | Payment requests | ✅ | ✅ Pass | ✅ | flag | `creqA...` codec is the canonical encoding for NUT-24's `X-Cashu` header too. |
| 19 | Cached responses (idempotency) | ✅ | ✅ Pass | ✅ | flag | **Phase 2.2 fixed the broken cache hash** — was a byte-sum modulo 256 (trivial collisions). Now uses real SHA-256. |
| 20 | Bitcoin on-chain support | 🟢 (Schnorr) / N/A in CoreCashu (on-chain) | ✅ Pass (BIP340) | mint-quote signing in CoreCashu | flag | **Phase 8.7 decision (2026-04-29):** the Schnorr mint-quote signing path is complete and vector-tested in CoreCashu. On-chain Bitcoin features (UTXO management, fee estimation) live in CashuKit (which depends on `bdk-swift`); CoreCashu does not implement on-chain because that would re-introduce a heavy Apple-only binary dependency. CashuKit-side on-chain support is itself "post-1.0 unless a concrete user requests it" — track in CashuKit's own status doc when it grows one. |
| 21 | Clear authentication (OIDC/JWT) | 🟡 | ✅ Pass (negative + positive cases) | new ``JWTVerifier`` | flag | **Phase 8.1 (2026-04-29):** real signature verification landed via `Sources/CoreCashu/NUTs/NUT21/JWT/`. ES256 (P-256 ECDSA via swift-crypto) + RS256 (PKCS#1 v1.5 via CryptoSwift). JWKS fetch with TTL caching. Standard claim validation (iss, aud, exp, nbf, iat) with configurable skew. `none` algorithm rejected unconditionally. 10 regression tests cover positive and negative paths. **First-pass implementation pending external audit** — keep capability flag off until Phase 9 audit completes. |
| 22 | Blind authentication (BAT) | 🟢 | — | full BAT issuance + pool | flag | **Phase 8.2 + follow-up (2026-04-29) — fully landed.** Issuing endpoint is `NUT22Endpoints.blindMint` (`/v1/auth/blind/mint`). DLEQ proofs at issuance are now verified via `NUT12.verifyDLEQProofAlice`. New `BlindAuthTokenPool` actor handles pool semantics (pre-mint, draw-one-per-protected-request, refresh-below-low-watermark). `BlindAuthHeader.apply(to:token:)` attaches the `Blind-auth: <token>` header. 5 regression tests cover the pool. Capability flag now safe to flip on after Phase 9 audit sign-off. |
| 23 | Multi-signature & keyset delegation | 🟡 | — | types only | flag-off | **Post-1.0 by Phase 8.8 decision (2026-04-29).** Type definitions present in `NUT23.swift`; no wallet-level integration and no public entry points to gate (yet). Capability flag stays off; the types are visible for spec compatibility and future development. Triggers reconsideration: concrete v1 user with multisig requirements. |
| 24 | HTTP 402 Payment Required | ✅ | ✅ Pass | ✅ | flag | **Phase 2.5 fixed the encoding** — payment requests now route through NUT-18 `creqA...` codec; `cashuB` payment tokens use NUT-00 V4 CBOR (was JSON+base64). |
| 25 | (reserved / non-allocated upstream) | N/A | — | — | — | **Phase 8.9 triage (2026-04-29):** upstream `cashubtc/nuts` does not assign NUT-25 to a concrete spec at this writing — the local snapshot reserved a slot. No action needed. |
| 26 | Bech32m payment requests | ❌ | — | — | — | **Post-1.0 by Phase 8.9 decision.** Bech32m-encoded variant of NUT-18 payment requests. Wallet works fine without it; consumers can still construct the existing `creqA...` codec. Triggers reconsideration: ecosystem migration to bech32m. |
| 27 | Nostr-based mint backup | ❌ | — | — | — | **Post-1.0 by Phase 8.9 decision.** Mint backup over Nostr — adds a Nostr dependency to anything that supports it. Not in v1 scope. |
| 28 | P2BK | ❌ | — | — | — | **Post-1.0 by Phase 8.9 decision.** Pay-to-Blinded-Key spending condition. The P2PK wallet API (NUT-11) covers the common public-key locking case for v1. |
| 29 | Batched minting | ❌ | — | — | — | **Post-1.0 by Phase 8.9 decision.** Batched mint endpoint. Not in v1 scope; existing per-amount mint flow is sufficient. |

## What "Capability flag" means

`Sources/CoreCashu/CapabilityDiscovery/MintFeatureCapabilities.swift` is the
single source of truth for what the wallet exposes. As of Phase 7.3 it is the
**runtime contract**: `CashuWallet.requireCapability(_:operation:)` is the
chokepoint, and every public method that exposes an optional NUT calls it
before doing any work. The flag defaults to off for any NUT that:

1. Does not pass official spec vectors in CI, or
2. Has known correctness gaps (status 🔧 in this matrix).

NUT-21 and NUT-22 remain status 🔧 — their flags are off and the wallet
refuses to talk to mints that require them, until Phase 2.3 / 2.4 land.

## Sources of truth

- Local doc snapshot: [`/claude/Nuts/`](../../claude/Nuts/) — frozen at the
  date the snapshot was taken.
- Upstream truth: [github.com/cashubtc/nuts](https://github.com/cashubtc/nuts)
  and [docs.cashu.space/protocol](https://docs.cashu.space/protocol).
- Test vectors: [`/claude/Nuts/tests/`](../../claude/Nuts/tests/) — used by
  `Tests/CoreCashuTests/` for vector-pass assertions.

## Re-baseline cadence

This matrix should be re-checked against upstream `cashubtc/nuts` at
minimum **before each release** and ideally **quarterly**. When upstream
adds or revises a NUT, an issue should be opened to triage scope.

## Change log

- **2026-04-28** — initial matrix. Phase 2.1, 2.2, 2.5 landed (NUT-11,
  NUT-19, NUT-24 fixes). Phase 2.3 (NUT-21 JWT verification) and Phase 2.4
  (NUT-22 endpoint+DLEQ) tracked but not yet implemented.
- **2026-04-28** — Phase 4 update. NUT-10 promoted to "complete" (the schema
  now flows through `prepareSwapToSend`'s `targetSecretFactory` hook). NUT-11
  promoted to "complete with public API" — `CashuWallet.sendLocked` /
  `unlockP2PK` added; the spec's exact signature vector cryptographically
  verifies under the Phase 2.1 Schnorr path. NUT-14 HTLC ops were
  rewritten to actually plumb the witness through swap (the previous
  implementation generated the HTLC secret and then discarded it). NUT-21
  (JWT) and NUT-22 (BAT endpoint+DLEQ) remain deferred to a follow-on
  session.
- **2026-04-29** — Phase 7 update. Capability flags are now wired as the
  runtime contract via `CashuWallet.requireCapability(_:operation:)`. Every
  high-level optional-NUT entry point (NUT-07 state check, NUT-09 restore,
  NUT-11 P2PK, NUT-14 HTLC) refuses to execute when the connected mint does
  not advertise the corresponding `MintFeatureCapability`. Three regression
  tests in `MockMintLockedSpendingTests` cover the contract end-to-end.
- **2026-04-29** — Phase 8 triage. NUT-15 (MPP) entry points now gate through
  `requireCapability(.mpp, ...)` and the row-15 status is "post-1.0." NUT-20
  on-chain features confirmed scoped to CashuKit (CoreCashu does only the
  Schnorr mint-quote signing, which is complete and vector-tested). NUT-23
  multisig stays type-only with the capability flag off. NUT-26/27/28/29
  triaged to post-1.0; NUT-25 noted as upstream-unassigned.
