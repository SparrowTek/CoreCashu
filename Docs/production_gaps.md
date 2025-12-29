# Production Gaps Checklist

Generated on 2025-01-14 from repository sweep of TODO/FIXME annotations in `Sources` and `Tests`.
Last Updated: 2025-09-26 after Phase 6 completion.

## CoreCashu Sources
- [x] `Sources/CoreCashu/CashuWallet.swift:10` – Replace BitcoinDevKit with cross-platform BIP39 implementation
- [x] `Sources/CoreCashu/CashuWallet.swift:296` – Add metrics hook `wallet.initialize.start` (✅ Already implemented)
- [x] `Sources/CoreCashu/CashuWallet.swift:297` – Implement performance logging during wallet initialization (✅ Timer implemented)
- [x] `Sources/CoreCashu/CashuWallet.swift:323` – Add metrics hook `wallet.initialize.success` (✅ Line 389)
- [x] `Sources/CoreCashu/CashuWallet.swift:327` – Add metrics hook `wallet.initialize.failure` (✅ Line 394)
- [x] `Sources/CoreCashu/CashuWallet.swift:577` – Add metrics hook `mint.start` (✅ Line 645)
- [x] `Sources/CoreCashu/CashuWallet.swift:578` – Implement performance logging for mint (✅ Timer at line 644)
- [x] `Sources/CoreCashu/CashuWallet.swift:585` – Add metrics hook `mint.success` (✅ Implemented in mint flow)
- [x] `Sources/CoreCashu/CashuWallet.swift:688` – Add metrics hook `melt.start` (✅ Line 758)
- [x] `Sources/CoreCashu/CashuWallet.swift:690` – Implement performance logging for melt (✅ Timer at line 757)
- [x] `Sources/CoreCashu/CashuWallet.swift:704` – Add metrics hook `melt.finalized` (✅ Line 773)
- [x] `Sources/CoreCashu/CashuWallet.swift:707` – Add metrics hook `melt.rolled_back` (✅ Line 777)
- [x] `Sources/CoreCashu/CashuWallet.swift:713` – Add metrics hook `melt.error` (✅ Line 783)
- [x] `Sources/CoreCashu/CashuWallet.swift:1033` – Reconstruct proof from stored token string (✅ Handled by ProofManager)
- [ ] `Sources/CoreCashu/NUTs/NUT20.swift:12` – Replace BitcoinDevKit with cross-platform implementation if needed

## CoreCashu Tests
- [ ] `Tests/CoreCashuTests/IntegrationTests.swift:16` – Unskip or implement integration test to pass
- [x] `Tests/CoreCashuTests/NUT13Tests.swift:12` – Replace BitcoinDevKit with cross-platform BIP39 implementation
- [x] `Tests/CoreCashuTests/NUT13Tests.swift:266` – Implement full BIP32 specification compliance (December 29, 2025)
- [x] `Tests/CoreCashuTests/NUT13Tests.swift:297` – Implement full BIP32 specification compliance (December 29, 2025)
- [x] `Tests/CoreCashuTests/NUT13Tests.swift:326` – Implement full BIP32 specification compliance (December 29, 2025)

### BIP32/NUT-13 Compliance (Completed December 29, 2025)
- All 5 secret test vectors from NUT-13 spec verified
- All 5 blinding factor test vectors from NUT-13 spec verified
- Added tests: BIP32 master key derivation, hardened child key derivation, passphrase handling, edge cases
