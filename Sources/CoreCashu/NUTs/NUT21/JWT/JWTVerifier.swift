//
//  JWTVerifier.swift
//  CoreCashu
//
//  NUT-21: Clear authentication — JWS signature verification (ES256 + RS256) and standard
//  claim validation. Phase 8.1 (2026-04-29).
//
//  ## Audit notes
//  This file is a first-pass implementation of JWT verification for OpenID Connect ID tokens
//  issued by a NUT-21 mint. It is intended for external security audit before being relied on
//  in production. Concerns to surface to the auditor:
//
//  - Base64url decoding lives in `Base64URL.decode(_:)` — verify it rejects padded input and
//    handles the empty string deterministically.
//  - ES256 verification uses `Crypto.P256.Signing.PublicKey` (swift-crypto). The JWS signature
//    layout is the IEEE P1363 fixed-width form (r||s, 64 bytes). swift-crypto exposes both
//    `.rawRepresentation` and `.derRepresentation` initializers; we use the raw form.
//  - RS256 verification uses `CryptoSwift.RSA` with PKCS#1 v1.5 padding and SHA-256. CryptoSwift
//    is slower than BoringSSL/OpenSSL paths but cross-platform and audit-feasible.
//  - Claim validation rejects tokens that lack `iss`, `aud`, `exp`. `iat` is optional but if
//    present must not be more than `clockSkew` seconds in the future. `nbf` is also optional.
//  - The `none` algorithm is rejected unconditionally.

import Foundation
import Crypto
import CryptoSwift

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// `Crypto.SHA256` (swift-crypto) and `CryptoSwift.SHA256` clash on the unqualified `SHA256`
// name; we always use fully-qualified `Crypto.SHA256` in this file.

/// Errors that the JWT verifier can produce. Wrapped into `CashuError.clearAuthFailed` /
/// `clearAuthExpired` at the boundary.
public enum JWTVerificationError: Error, Sendable, Equatable {
    case malformedToken
    case unsupportedAlgorithm(String)
    case missingKID
    case algorithmMismatch(headerAlg: String, jwkAlg: String)
    case missingClaim(String)
    case invalidIssuer(expected: String, got: String)
    case invalidAudience(expected: String)
    case tokenExpired
    case tokenNotYetValid
    case issuedInFuture
    case signatureVerificationFailed
    case unsupportedKeyType(String)
    case malformedJWK(String)
}

// MARK: - Configuration

public struct JWTValidationConfig: Sendable {
    /// Expected `iss` claim. Required.
    public let issuer: String
    /// Expected `aud` claim — the token must list this audience.
    public let audience: String
    /// Tolerance for clock skew on time-based claims (default ±300 seconds).
    public let clockSkew: TimeInterval
    /// Allowed algorithms — defaults to `ES256` and `RS256` (the spec's required set).
    public let allowedAlgorithms: Set<String>

    public init(
        issuer: String,
        audience: String,
        clockSkew: TimeInterval = 300,
        allowedAlgorithms: Set<String> = ["ES256", "RS256"]
    ) {
        self.issuer = issuer
        self.audience = audience
        self.clockSkew = clockSkew
        self.allowedAlgorithms = allowedAlgorithms
    }
}

// MARK: - Verifier

/// Stateless verifier — pass it the raw JWS string and a `JWKSClient`; it returns the decoded
/// `ClearAuthToken` on success and throws on any verification failure.
public struct JWTVerifier: Sendable {
    public init() {}

    public func verify(
        jws: String,
        jwksClient: JWKSClient,
        jwksURL: URL,
        config: JWTValidationConfig,
        now: @Sendable () -> Date = { Date() }
    ) async throws -> ClearAuthToken {
        let parts = jws.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else {
            throw JWTVerificationError.malformedToken
        }
        let headerB64 = parts[0]
        let payloadB64 = parts[1]
        let signatureB64 = parts[2]

        guard let headerData = Base64URL.decode(headerB64),
              let payloadData = Base64URL.decode(payloadB64),
              let signatureBytes = Base64URL.decode(signatureB64) else {
            throw JWTVerificationError.malformedToken
        }

        let header: JWTHeader
        let payload: JWTPayload
        do {
            header = try JSONDecoder().decode(JWTHeader.self, from: headerData)
            payload = try JSONDecoder().decode(JWTPayload.self, from: payloadData)
        } catch {
            throw JWTVerificationError.malformedToken
        }

        try validateAlgorithm(header: header, allowed: config.allowedAlgorithms)
        try validateClaims(payload: payload, config: config, now: now())

        guard let kid = header.kid else {
            throw JWTVerificationError.missingKID
        }
        let jwk = try await jwksClient.key(forKID: kid, at: jwksURL)

        if let jwkAlg = jwk.alg, jwkAlg != header.alg {
            throw JWTVerificationError.algorithmMismatch(headerAlg: header.alg, jwkAlg: jwkAlg)
        }

        let signingInputBytes = Data((headerB64 + "." + payloadB64).utf8)

        switch header.alg {
        case "ES256":
            try verifyES256(jwk: jwk, signature: signatureBytes, signingInput: signingInputBytes)
        case "RS256":
            try verifyRS256(jwk: jwk, signature: signatureBytes, signingInput: signingInputBytes)
        default:
            throw JWTVerificationError.unsupportedAlgorithm(header.alg)
        }

        // ClearAuthToken's only public init parses the JWS string itself; signature has already
        // been verified above, so we re-parse to populate the typed fields. The structure-only
        // parse is cheap (two base64 decodes + JSON), and avoids duplicating ClearAuthToken's
        // memberwise init.
        return try ClearAuthToken(rawToken: jws)
    }

    // MARK: - Algorithm + claim helpers

    private func validateAlgorithm(header: JWTHeader, allowed: Set<String>) throws {
        // RFC 8725 §3.1: reject "none" unconditionally.
        guard header.alg != "none", header.alg != "None", header.alg != "NONE" else {
            throw JWTVerificationError.unsupportedAlgorithm("none")
        }
        guard allowed.contains(header.alg) else {
            throw JWTVerificationError.unsupportedAlgorithm(header.alg)
        }
    }

    private func validateClaims(
        payload: JWTPayload,
        config: JWTValidationConfig,
        now: Date
    ) throws {
        // iss
        guard let iss = payload.iss else {
            throw JWTVerificationError.missingClaim("iss")
        }
        guard iss == config.issuer else {
            throw JWTVerificationError.invalidIssuer(expected: config.issuer, got: iss)
        }

        // aud (string or array per RFC 7519 §4.1.3)
        guard let aud = payload.aud else {
            throw JWTVerificationError.missingClaim("aud")
        }
        let audMatched = matches(audience: aud, expected: config.audience)
        guard audMatched else {
            throw JWTVerificationError.invalidAudience(expected: config.audience)
        }

        // exp (required)
        guard let exp = payload.exp else {
            throw JWTVerificationError.missingClaim("exp")
        }
        let expDate = Date(timeIntervalSince1970: exp)
        if now > expDate.addingTimeInterval(config.clockSkew) {
            throw JWTVerificationError.tokenExpired
        }

        // nbf (optional)
        if let nbf = payload.nbf {
            let nbfDate = Date(timeIntervalSince1970: nbf)
            if now < nbfDate.addingTimeInterval(-config.clockSkew) {
                throw JWTVerificationError.tokenNotYetValid
            }
        }

        // iat (optional but when present must not be in the future beyond skew)
        if let iat = payload.iat {
            let iatDate = Date(timeIntervalSince1970: iat)
            if now < iatDate.addingTimeInterval(-config.clockSkew) {
                throw JWTVerificationError.issuedInFuture
            }
        }
    }

    private func matches(audience aud: AnyCodable, expected: String) -> Bool {
        switch aud {
        case .string(let single):
            return single == expected
        case .array(let list):
            return list.contains { $0.stringValue == expected }
        default:
            return false
        }
    }

    // MARK: - Algorithm-specific verifiers

    private func verifyES256(jwk: JWK, signature: Data, signingInput: Data) throws {
        guard jwk.kty == "EC" else {
            throw JWTVerificationError.unsupportedKeyType(jwk.kty)
        }
        guard let crv = jwk.crv, crv == "P-256" else {
            throw JWTVerificationError.malformedJWK("ES256 requires curve P-256")
        }
        guard let xB64 = jwk.x, let yB64 = jwk.y,
              let xBytes = Base64URL.decode(xB64),
              let yBytes = Base64URL.decode(yB64) else {
            throw JWTVerificationError.malformedJWK("ES256 JWK missing x/y coordinates")
        }
        // P-256 raw uncompressed form: 0x04 || x (32) || y (32). swift-crypto's
        // x963Representation initializer expects exactly this layout.
        guard xBytes.count == 32, yBytes.count == 32 else {
            throw JWTVerificationError.malformedJWK("ES256 x/y coordinates must each be 32 bytes")
        }
        var raw = Data([0x04])
        raw.append(xBytes)
        raw.append(yBytes)

        let publicKey: P256.Signing.PublicKey
        do {
            publicKey = try P256.Signing.PublicKey(x963Representation: raw)
        } catch {
            throw JWTVerificationError.malformedJWK("ES256 JWK did not yield a valid P-256 public key: \(error.localizedDescription)")
        }

        // JWS signature for ES256 is r || s, fixed-width 64 bytes (32 + 32). swift-crypto's
        // ECDSASignature(rawRepresentation:) expects exactly this layout.
        guard signature.count == 64 else {
            throw JWTVerificationError.signatureVerificationFailed
        }
        let signatureObject: P256.Signing.ECDSASignature
        do {
            signatureObject = try P256.Signing.ECDSASignature(rawRepresentation: signature)
        } catch {
            throw JWTVerificationError.signatureVerificationFailed
        }

        let digest = Crypto.SHA256.hash(data: signingInput)
        guard publicKey.isValidSignature(signatureObject, for: digest) else {
            throw JWTVerificationError.signatureVerificationFailed
        }
    }

    private func verifyRS256(jwk: JWK, signature: Data, signingInput: Data) throws {
        guard jwk.kty == "RSA" else {
            throw JWTVerificationError.unsupportedKeyType(jwk.kty)
        }
        guard let nB64 = jwk.n, let eB64 = jwk.e,
              let modulus = Base64URL.decode(nB64),
              let exponent = Base64URL.decode(eB64) else {
            throw JWTVerificationError.malformedJWK("RS256 JWK missing modulus/exponent")
        }

        // CryptoSwift's RSA `init(n:e:)` accepts Array<UInt8>. The verify variant
        // `.message_pkcs1v15_SHA256` instructs CryptoSwift to apply SHA-256 internally and
        // PKCS#1 v1.5 padding — i.e., we pass the raw signing-input bytes, not the digest.
        let rsa = CryptoSwift.RSA(n: Array(modulus), e: Array(exponent))

        let signatureBytes = Array(signature)
        let signingInputBytes = Array(signingInput)

        let verified: Bool
        do {
            verified = try rsa.verify(
                signature: signatureBytes,
                for: signingInputBytes,
                variant: .message_pkcs1v15_SHA256
            )
        } catch {
            throw JWTVerificationError.signatureVerificationFailed
        }
        guard verified else {
            throw JWTVerificationError.signatureVerificationFailed
        }
    }
}

// MARK: - Base64URL helper

/// Base64url codec (RFC 4648 §5) — same alphabet as base64 with `-`/`_` for `+`/`/` and no
/// padding by convention. JWT uses base64url so we need an explicit decoder; Foundation's
/// `Data(base64Encoded:)` doesn't accept the `-`/`_` alphabet without translation.
public enum Base64URL {
    public static func decode(_ s: String) -> Data? {
        var fixed = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let mod = fixed.count % 4
        if mod != 0 {
            fixed.append(String(repeating: "=", count: 4 - mod))
        }
        return Data(base64Encoded: fixed)
    }

    public static func encode(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return s
    }
}
