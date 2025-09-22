# CoreCashu Threat Model (Outline Draft)

> Status: Draft outline prepared on 2025-09-22. Populate with detailed analysis before external review.

## 1. Scope
- Components: CoreCashu library (wallet APIs, secure storage, networking client abstractions)
- Environments: Apple platforms (iOS, macOS, visionOS, watchOS, tvOS), Linux server deployments, WASM (future)
- Exclusions: CashuKit UI surfaces, mint-side implementations, BOLT-12/NUT-25 extensions

## 2. Assets & Trust Assumptions
- Secrets: wallet mnemonics, seeds, access tokens, pending proofs, HTLC preimages
- Integrity-critical data: proofs ledger, mint configuration, keysets, invoice metadata
- Availability targets: swap/melt/mint workflow state machines, secure storage persistence
- Trusted components: system CSPRNG, platform TLS stack, filesystem permissions (0o600/0o700)

## 3. Adversaries & Motivations
- External mint or network observer attempting to correlate user activity or exfiltrate tokens
- Local attacker with filesystem/process access on client device
- Malicious dependency or supply-chain actor tampering with builds
- Memory inspection / side-channel attacker on shared hardware

## 4. Attack Surfaces
- API boundary: malformed protocol responses, overlong proofs, hostile CBOR/JSON payloads
- Storage boundary: compromised Keychain/FileSecureStore file system, backup media leakage
- Concurrency boundary: reentrancy, actor-hopping, and sendable violations leading to data races
- Cryptography boundary: weak randomness, key reuse, signature malleability, timing side-channels
- Networking boundary: TLS stripping, retry flooding, WebSocket reconnection abuse

## 5. Existing Controls
- RNG unification via `SecureRandom.generateBytes` with injectable deterministic overrides
- Actor isolation and `Sendable` audits for wallet state transitions
- AES.GCM encryption, POSIX permission hardening, best-effort zeroization in `FileSecureStore`
- Regression tests for BDHKE, P2PK, HTLC, and deterministic mnemonic recovery

## 6. Gaps & Planned Mitigations
- Pending Keychain secure store for Apple platforms (Phase 2)
- Rate limiting, circuit breaker, and TLS pinning for networking layer (Phase 3)
- Comprehensive BIP32 vector coverage and serialization fuzzing (Phase 6)
- Formal incident response and operational playbooks (Phase 7+)
- Third-party cryptography and security audit prior to production rollout

## 7. Next Steps
- Flesh out threat scenarios with STRIDE-style mapping per component
- Quantify severity/likelihood matrix and residual risk per asset
- Link mitigations to `Docs/production_gaps.md` entries and roadmap phases
- Capture monitoring/telemetry requirements powering incident response
