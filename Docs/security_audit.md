# Security Audit – Randomness & Key Handling

- **Date:** 2025-09-22
- **Scope:** `Sources/CoreCashu/Security`, `Sources/CoreCashu/Protocols`, and all call sites of secure random generation & key material handling in CoreCashu.

## Summary

- Cryptographically secure randomness is available via `SecureRandom.generateBytes`, which uses `SecRandomCopyBytes` on Apple platforms and `SystemRandomNumberGenerator` elsewhere. Key derivation paths in `FileSecureStore` and DLEQ utilities already rely on this API.
- Several callers still use `UInt8.random(in:)` or `Data.random(count:)` directly when creating secrets (e.g. `CashuKeyUtils.generateRandomSecret`, BIP340 auxiliary randomness in `NUT20SignatureManager`, SecureMemory overwrite passes). While Swift’s default RNG is cryptographically secure, these sites bypass our error-handling surface and make it harder to swap in deterministic generators for testing.
- Key storage implementations (`FileSecureStore`) enforce 0o600/0o700 permissions, leverage CryptoSwift AES-GCM envelopes with per-item nonces, and persist salts/keys generated through secure sources.
- Protocol definitions do not leak implementation details; all stateful storage is actor-isolated.

## Recommendations

1. **Unify random byte creation** – ✅ 2025-09-22: all production call sites now route through `SecureRandom.generateBytes`; `SecureMemory` falls back to a fixed pattern only if randomness fails.
2. **Expose deterministic testing hook** – ✅ 2025-09-22: `SecureRandom.installGenerator` enables injectable RNGs for fuzzing and tests.
3. **Document zeroization guarantees** – ✅ 2025-09-22: `SecureMemory` docs now call out best-effort semantics; revisit `Data.resetBytes` once available for stronger guarantees.
4. **Add property tests around key generation** – ✅ 2025-09-22: `KeyGenerationPropertyTests` covers hex format, byte length, non-zero enforcement, and collision sampling.

## Next Actions

- Track the migration of `UInt8.random` call sites via `Docs/production_gaps.md` or dedicated tickets. (Completed for production sources; update if new usages appear.)
- If we need platform parity on Linux, audit `SystemRandomNumberGenerator` behavior under WASM once wasm builds are enabled.
- Revisit `SecureMemory` once Swift exposes better low-level volatile writes; current approach is acceptable but not formally verified.
