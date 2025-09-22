# KeychainSecureStore Design Scope (Phase 2 Draft)

> Status: Prototype scaffolding added on 2025-09-22; update this document as implementation matures.

## 1. Goals
- Provide a production-ready secure store for Apple platforms that implements `SecureStore`.
- Persist wallet secrets (mnemonics, seeds, access tokens, token lists) using the system Keychain with appropriate access controls.
- Support async/await API surface while respecting Keychain’s thread-affinity and blocking behavior.
- Maintain compatibility with unit testing by supplying in-memory or deterministic shims via dependency injection.

## 2. Non-goals
- Cross-platform abstraction for non-Apple platforms (covered by `FileSecureStore`).
- UI-driven authentication flows (Face ID/Touch ID prompts) beyond basic access control configuration.
- Multi-user keychain synchronization (iCloud Keychain) in initial release; defer to future roadmap item if needed.

## 3. Platform & Build Guards
- File to live under `Sources/CoreCashu/SecureStorage/KeychainSecureStore.swift`.
- Wrap implementation with `#if canImport(Security) && !os(Linux)` (covers iOS, macOS, tvOS, watchOS, visionOS).
- Expose as part of the `CoreCashu` module; register default selection in wallet factories when running on supported OS.

## 4. API Surface
- Declare `public actor KeychainSecureStore: SecureStore` to align with existing async protocol.
- Internal helpers wrap Keychain queries via `SecItemAdd`, `SecItemCopyMatching`, `SecItemUpdate`, `SecItemDelete`.
- Use service identifiers namespaced under `"cashu.core"` plus item-specific suffixes (e.g., `"cashu.core.mnemonic"`).
- Encode complex payloads (token dictionaries/lists) as JSON before storing; enforce `.utf8` serialization with envelope struct to allow future versioning.
- Provide initializer accepting optional `accessGroup`; plumb configurable `SecAccessControl` in a follow-up revision. Default to `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` for now.

## 5. Security & Access Control
- Store mnemonics/seeds as `kSecClassKey` or `kSecClassGenericPassword` items with `kSecAttrSynchronizable` disabled.
- Configure `SecAccessControl` with `.biometryAny` or `.userPresence` opt-in (TODO); default to no UI requirement for background usage until that lands.
- Ensure items are set with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` to prevent iCloud sync and limit to device.
- Consider `SecItemDelete` zeroization limitations; rely on Keychain semantics plus memory scrubbing before submission.

## 6. Error Handling & Logging
- Map common `OSStatus` codes to `SecureStoreError` cases (e.g., `.itemNotFound`, `.duplicateItem`, `.permissionDenied`).
- Provide helper to translate `OSStatus` into human-readable strings for debugging while redacting item identifiers in logs.
- Bubble errors via `throw` to caller; avoid silent fallback to in-memory store.

## 7. Testing Strategy
- Use `@testing` conditional compilation to insert an in-memory mock conforming to `SecureStore` for unit tests.
- Add async XCTest replacements (Swift Testing) under `Tests/CoreCashuTests/SecureStoreKeychainTests.swift` using `KeychainSwiftTestDouble` if direct Keychain access unavailable in CI.
- For device/simulator manual tests, document steps to inspect items using `security find-generic-password -s cashu.core.*`.
- Validate concurrent save/load/delete operations to ensure actor isolation works as expected.

## 8. Migration Plan
- Update wallet factory defaults: prefer `KeychainSecureStore` on Apple platforms, fall back to `FileSecureStore`/`InMemorySecureStore` elsewhere.
- Mark `InMemorySecureStore` as deprecated for production via availability annotations once Keychain version lands.
- Update README security section with new guidance and add manual testing checklist to `Docs/operational_checklist.md` (future work).

## 9. Open Questions
- Should we support customizable Keychain access group for app extensions/shared keychain? (Default: optional `String?` parameter).
- Do we require biometrics gating for sensitive operations, and if so how to expose configuration to developers?
- What is the fallback strategy if Keychain APIs are unavailable (e.g., Mac Catalyst without entitlement)? Prospect: throw explicit configuration error.

## 10. Next Actions
- Prototype Keychain CRUD helpers in isolation with Swift Testing harness.
- Define item attribute constants and serialization envelope types.
- Coordinate with CoreCashu wallet initialization to inject store based on platform checks.
- Revisit threat model section once implementation is complete to capture residual risk.
