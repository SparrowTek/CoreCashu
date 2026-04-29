// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "CoreCashu",
    platforms: [
        .macOS(.v15),
        .iOS(.v17),
        .tvOS(.v17),
        .watchOS(.v10),
        .macCatalyst(.v17)
    ],
    products: [
        .library(
            name: "CoreCashu",
            targets: ["CoreCashu"]),
    ],
    dependencies: [
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1.git", from: "0.23.0"),
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", from: "1.10.0"),
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.7.0"),
        .package(url: "https://github.com/valpackett/SwiftCBOR.git", from: "0.6.0"),
        // swift-crypto provides cross-platform P-256 ECDSA (ES256) for NUT-21 JWT verification.
        // It is API-compatible with Apple's CryptoKit and works on Linux. Added in Phase 8.1.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        // Apple-specific dependencies removed (bdk-swift, Vault)
        // These will be added in the CashuKit package
    ],
    targets: [
        .target(
            name: "CoreCashu",
            dependencies: [
                .product(name: "P256K", package: "swift-secp256k1"),
                .product(name: "CryptoSwift", package: "CryptoSwift"),
                .product(name: "BigInt", package: "BigInt"),
                .product(name: "SwiftCBOR", package: "SwiftCBOR"),
                .product(name: "Crypto", package: "swift-crypto"),
                // Platform-specific dependencies removed
            ],
            resources: [
                .copy("Resources/bip39-english.txt")
            ],
            // Swift 6 language mode (declared below in `swiftLanguageModes`) implies
            // `-strict-concurrency=complete` for both debug and release. The previous
            // `unsafeFlags(["-strict-concurrency=complete"], .when(configuration: .debug))`
            // setting was redundant in debug *and* let release skip strict checks — exactly
            // the gap CODEX flagged. Drop it.
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .testTarget(
            name: "CoreCashuTests",
            dependencies: ["CoreCashu"],
            swiftSettings: [
                .define("TESTING")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
