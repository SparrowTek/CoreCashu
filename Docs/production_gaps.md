# Production Gaps Checklist

Generated on 2025-01-14 from repository sweep of TODO/FIXME annotations in `Sources` and `Tests`.

## CoreCashu Sources
- [x] `Sources/CoreCashu/CashuWallet.swift:10` – Replace BitcoinDevKit with cross-platform BIP39 implementation
- [ ] `Sources/CoreCashu/CashuWallet.swift:296` – Add metrics hook `wallet.initialize.start`
- [ ] `Sources/CoreCashu/CashuWallet.swift:297` – Implement performance logging during wallet initialization
- [ ] `Sources/CoreCashu/CashuWallet.swift:323` – Add metrics hook `wallet.initialize.success`
- [ ] `Sources/CoreCashu/CashuWallet.swift:327` – Add metrics hook `wallet.initialize.failure`
- [ ] `Sources/CoreCashu/CashuWallet.swift:577` – Add metrics hook `mint.start`
- [ ] `Sources/CoreCashu/CashuWallet.swift:578` – Implement performance logging for mint
- [ ] `Sources/CoreCashu/CashuWallet.swift:585` – Add metrics hook `mint.success`
- [ ] `Sources/CoreCashu/CashuWallet.swift:688` – Add metrics hook `melt.start`
- [ ] `Sources/CoreCashu/CashuWallet.swift:690` – Implement performance logging for melt
- [ ] `Sources/CoreCashu/CashuWallet.swift:704` – Add metrics hook `melt.finalized`
- [ ] `Sources/CoreCashu/CashuWallet.swift:707` – Add metrics hook `melt.rolled_back`
- [ ] `Sources/CoreCashu/CashuWallet.swift:713` – Add metrics hook `melt.error`
- [ ] `Sources/CoreCashu/CashuWallet.swift:1033` – Reconstruct proof from stored token string
- [ ] `Sources/CoreCashu/NUTs/NUT20.swift:12` – Replace BitcoinDevKit with cross-platform implementation if needed

## CoreCashu Tests
- [ ] `Tests/CoreCashuTests/IntegrationTests.swift:16` – Unskip or implement integration test to pass
- [x] `Tests/CoreCashuTests/NUT13Tests.swift:12` – Replace BitcoinDevKit with cross-platform BIP39 implementation
- [ ] `Tests/CoreCashuTests/NUT13Tests.swift:266` – Implement full BIP32 specification compliance
- [ ] `Tests/CoreCashuTests/NUT13Tests.swift:297` – Implement full BIP32 specification compliance
- [ ] `Tests/CoreCashuTests/NUT13Tests.swift:326` – Implement full BIP32 specification compliance
