# NUT Status Matrix

**Last updated:** 2026-04-28 (Phase 2 of `/opus47.md`)

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
| 10 | Spending conditions (well-known secret) | ✅ | ✅ Pass | types only | flag | Conditions schema works; no high-level wallet API (Phase 4.2). |
| 11 | P2PK | ✅ | ✅ Pass | partial | flag | **Phase 2.1 fixed the consensus bug** — was verifying with Curve25519 instead of secp256k1 BIP340 Schnorr. Multisig duplicate-key check added. High-level `wallet.send(to publicKey:)` API still pending (Phase 4.2). |
| 12 | DLEQ proofs | ✅ | ✅ Pass | ✅ | flag | |
| 13 | Deterministic secrets (BIP39/BIP32) | ✅ | ✅ Pass | ✅ | n/a | |
| 14 | HTLC | 🟡 | — | types only | flag | Primitives present; high-level swap/atomic flows pending (Phase 4.2). |
| 15 | Multi-path payments | 🟡 | — | partial | flag | MPP primitives present; routing/pathfinding incomplete. **Will not ship in 1.0** — keep capability flag off. |
| 16 | Animated QR codes | 🟡 | — | partial | flag | Frame generation present; animation/UX layer belongs in CashuKit. |
| 17 | WebSocket subscriptions | 🟡 | — | partial | flag | `RobustWebSocketClient`, `ReconnectionStrategy` present. Apple-platform only until cross-platform WS lands (Phase 3). |
| 18 | Payment requests | ✅ | ✅ Pass | ✅ | flag | `creqA...` codec is the canonical encoding for NUT-24's `X-Cashu` header too. |
| 19 | Cached responses (idempotency) | ✅ | ✅ Pass | ✅ | flag | **Phase 2.2 fixed the broken cache hash** — was a byte-sum modulo 256 (trivial collisions). Now uses real SHA-256. |
| 20 | Bitcoin on-chain support | 🟡 | ✅ Pass (BIP340) | partial | flag | Schnorr signing/verifying paths fixed in Phase 1.3 dependency bump. On-chain fee estimation incomplete. |
| 21 | Clear authentication (OIDC/JWT) | 🔧 | — | partial | flag | **JWT signature verification is a no-op today** — only checks alg field and non-empty signature. JWKS not fetched, signatures not verified. **Tracked for Phase 2.3.** Capability flag must remain off until fixed. |
| 22 | Blind authentication (BAT) | 🔧 | — | partial | flag | **Wrong endpoint and request shape** — uses `/v1/access` and `access_token` body field. Spec uses `/v1/auth/blind/mint` + `Blind-auth: <token>` header, with one BAT consumed per protected request and DLEQ proofs verified at issuance. **Tracked for Phase 2.4.** Capability flag must remain off until fixed. |
| 23 | Multi-signature & keyset delegation | 🟡 | — | types only | flag | Type definitions present; no wallet-level integration. |
| 24 | HTTP 402 Payment Required | ✅ | ✅ Pass | ✅ | flag | **Phase 2.5 fixed the encoding** — payment requests now route through NUT-18 `creqA...` codec; `cashuB` payment tokens use NUT-00 V4 CBOR (was JSON+base64). |
| 25 | (reserved) | ❌ | — | — | — | Local doc snapshot only. Decide ship-or-defer in Phase 4.3. |
| 26 | Bech32m payment requests | ❌ | — | — | — | Not in local snapshot. Upstream-only. Defer to post-1.0 unless a v1 user requests it. |
| 27 | Nostr-based mint backup | ❌ | — | — | — | Not in local snapshot. Upstream-only. Likely post-1.0. |
| 28 | P2BK | ❌ | — | — | — | Not in local snapshot. Upstream-only. Decide in Phase 4.3. |
| 29 | Batched minting | ❌ | — | — | — | Not in local snapshot. Upstream-only. Likely post-1.0. |

## What "Capability flag" means

`Sources/CoreCashu/NUTs/MintFeatureCapabilities.swift` is intended to be the
single source of truth for what the wallet exposes. Phase 7.3 makes this the
contract: the wallet should refuse to expose a NUT's operations unless the
flag is set, and the flag should default to off for any NUT that:

1. Does not pass official spec vectors in CI, or
2. Has known correctness gaps (status 🔧 in this matrix).

Today the capability flags exist but are not consistently checked at the
public-API boundary. Phase 7.3 closes that gap.

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
