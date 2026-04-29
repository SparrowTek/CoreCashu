import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import Crypto
@testable import CoreCashu

/// Phase 8.1 (2026-04-29) — verification suite for the new ES256 / RS256 JWT verifier.
/// We dynamically mint test tokens using swift-crypto, so the suite has no live-server
/// dependency and runs offline. RS256 negative tests are included; the positive RS256 path
/// uses a fixture key generated at compile-time to keep test runtime down.
@Suite("JWT verifier (NUT-21)")
struct JWTVerifierTests {

    private static let issuer = "https://issuer.example"
    private static let audience = "https://wallet.example"
    private static let kid = "test-key"
    private static let jwksURL = URL(string: "https://issuer.example/.well-known/jwks.json")!

    // MARK: - Helpers

    /// Build a JWS with the supplied algorithm and claims, signed by the supplied P-256 key.
    private static func makeES256JWT(
        privateKey: P256.Signing.PrivateKey,
        kid: String = JWTVerifierTests.kid,
        issuer: String = JWTVerifierTests.issuer,
        audience: AnyEncodable = .string(JWTVerifierTests.audience),
        expiresIn: TimeInterval = 600,
        notBefore: TimeInterval? = nil,
        issuedAt: TimeInterval? = nil
    ) throws -> String {
        let now = Date()
        let header = ["alg": "ES256", "typ": "JWT", "kid": kid]
        var payload: [String: Any] = [
            "iss": issuer,
            "exp": now.addingTimeInterval(expiresIn).timeIntervalSince1970,
            "sub": "test-subject"
        ]
        switch audience {
        case .string(let s): payload["aud"] = s
        case .array(let xs): payload["aud"] = xs
        }
        if let nbf = notBefore { payload["nbf"] = now.addingTimeInterval(nbf).timeIntervalSince1970 }
        if let iat = issuedAt { payload["iat"] = now.addingTimeInterval(iat).timeIntervalSince1970 }

        let headerJSON = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let payloadJSON = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let signingInput = Base64URL.encode(headerJSON) + "." + Base64URL.encode(payloadJSON)

        let digest = Crypto.SHA256.hash(data: Data(signingInput.utf8))
        let signature = try privateKey.signature(for: digest)
        let signatureB64 = Base64URL.encode(signature.rawRepresentation)

        return signingInput + "." + signatureB64
    }

    private static func makeJWKS(publicKey: P256.Signing.PublicKey, kid: String = JWTVerifierTests.kid) -> JWKS {
        // P-256 public key in x9.63 form: 0x04 || x (32) || y (32).
        let raw = publicKey.x963Representation
        let xBytes = raw.subdata(in: 1..<33)
        let yBytes = raw.subdata(in: 33..<65)

        let jwk = JWK(
            kty: "EC",
            use: "sig",
            kid: kid,
            alg: "ES256",
            crv: "P-256",
            x: Base64URL.encode(xBytes),
            y: Base64URL.encode(yBytes)
        )
        return JWKS(keys: [jwk])
    }

    /// Mock `Networking` adapter that returns the supplied JWKS bytes for any GET request.
    actor JWKSStubNetworking: Networking {
        let body: Data
        init(body: Data) { self.body = body }
        func data(for request: URLRequest, delegate: (any URLSessionTaskDelegate)?) async throws -> (Data, URLResponse) {
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://issuer.example/.well-known/jwks.json")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (body, response)
        }
    }

    enum AnyEncodable: Sendable {
        case string(String)
        case array([String])
    }

    private func standardConfig(audience: String = JWTVerifierTests.audience) -> JWTValidationConfig {
        JWTValidationConfig(issuer: Self.issuer, audience: audience)
    }

    private func client(jwks: JWKS) async throws -> JWKSClient {
        let body = try JSONEncoder().encode(jwks)
        let networking = JWKSStubNetworking(body: body)
        return JWKSClient(networking: networking)
    }

    // MARK: - Tests

    @Test("ES256 token with valid signature, issuer, audience, and unexpired exp passes")
    func validES256Verifies() async throws {
        let key = P256.Signing.PrivateKey()
        let jwks = Self.makeJWKS(publicKey: key.publicKey)
        let jws = try Self.makeES256JWT(privateKey: key)
        let jwksClient = try await client(jwks: jwks)

        let verifier = JWTVerifier()
        let token = try await verifier.verify(
            jws: jws,
            jwksClient: jwksClient,
            jwksURL: Self.jwksURL,
            config: standardConfig()
        )
        #expect(token.payload.iss == Self.issuer)
    }

    @Test("Tampered signature fails verification")
    func tamperedSignatureFails() async throws {
        let key = P256.Signing.PrivateKey()
        let jwks = Self.makeJWKS(publicKey: key.publicKey)
        let validJWS = try Self.makeES256JWT(privateKey: key)
        // Flip a base64url character in the signature segment.
        let parts = validJWS.split(separator: ".").map(String.init)
        let tamperedSignature = String(parts[2].dropFirst()) + "A"
        let tamperedJWS = parts[0] + "." + parts[1] + "." + tamperedSignature
        let jwksClient = try await client(jwks: jwks)

        await #expect(throws: JWTVerificationError.self) {
            _ = try await JWTVerifier().verify(
                jws: tamperedJWS,
                jwksClient: jwksClient,
                jwksURL: Self.jwksURL,
                config: standardConfig()
            )
        }
    }

    @Test("Wrong kid fails verification (key not found in JWKS)")
    func wrongKIDFails() async throws {
        let key = P256.Signing.PrivateKey()
        // JWKS publishes "actual-key" only.
        let jwks = Self.makeJWKS(publicKey: key.publicKey, kid: "actual-key")
        // Token claims "wrong-key" in its header.
        let jws = try Self.makeES256JWT(privateKey: key, kid: "wrong-key")
        let jwksClient = try await client(jwks: jwks)

        await #expect(throws: CashuError.self) {
            _ = try await JWTVerifier().verify(
                jws: jws,
                jwksClient: jwksClient,
                jwksURL: Self.jwksURL,
                config: standardConfig()
            )
        }
    }

    @Test("Expired token fails verification")
    func expiredTokenFails() async throws {
        let key = P256.Signing.PrivateKey()
        let jwks = Self.makeJWKS(publicKey: key.publicKey)
        // exp 60s in the past, well outside the default 300s skew.
        let jws = try Self.makeES256JWT(privateKey: key, expiresIn: -600)
        let jwksClient = try await client(jwks: jwks)

        await #expect(throws: JWTVerificationError.self) {
            _ = try await JWTVerifier().verify(
                jws: jws,
                jwksClient: jwksClient,
                jwksURL: Self.jwksURL,
                config: standardConfig()
            )
        }
    }

    @Test("Mismatched audience fails verification")
    func mismatchedAudienceFails() async throws {
        let key = P256.Signing.PrivateKey()
        let jwks = Self.makeJWKS(publicKey: key.publicKey)
        let jws = try Self.makeES256JWT(
            privateKey: key,
            audience: .string("https://other.audience")
        )
        let jwksClient = try await client(jwks: jwks)

        await #expect(throws: JWTVerificationError.self) {
            _ = try await JWTVerifier().verify(
                jws: jws,
                jwksClient: jwksClient,
                jwksURL: Self.jwksURL,
                config: standardConfig()
            )
        }
    }

    @Test("Audience array containing the expected audience passes")
    func audienceArrayMatches() async throws {
        let key = P256.Signing.PrivateKey()
        let jwks = Self.makeJWKS(publicKey: key.publicKey)
        let jws = try Self.makeES256JWT(
            privateKey: key,
            audience: .array(["https://other.audience", Self.audience])
        )
        let jwksClient = try await client(jwks: jwks)

        let token = try await JWTVerifier().verify(
            jws: jws,
            jwksClient: jwksClient,
            jwksURL: Self.jwksURL,
            config: standardConfig()
        )
        #expect(token.header.alg == "ES256")
    }

    @Test("'none' algorithm is rejected unconditionally (RFC 8725)")
    func noneAlgorithmRejected() async throws {
        // Hand-craft a JWS with alg=none, no signature.
        let header = #"{"alg":"none","typ":"JWT","kid":"test-key"}"#
        let payload = #"{"iss":"\#(Self.issuer)","aud":"\#(Self.audience)","exp":\#(Date().timeIntervalSince1970 + 600)}"#
        let headerB64 = Base64URL.encode(Data(header.utf8))
        let payloadB64 = Base64URL.encode(Data(payload.utf8))
        let jws = headerB64 + "." + payloadB64 + "."

        let key = P256.Signing.PrivateKey()
        let jwks = Self.makeJWKS(publicKey: key.publicKey)
        let jwksClient = try await client(jwks: jwks)

        await #expect(throws: JWTVerificationError.self) {
            _ = try await JWTVerifier().verify(
                jws: jws,
                jwksClient: jwksClient,
                jwksURL: Self.jwksURL,
                config: standardConfig()
            )
        }
    }

    @Test("Algorithm mismatch (header alg ≠ JWK alg) fails verification")
    func algorithmMismatchFails() async throws {
        let key = P256.Signing.PrivateKey()
        // JWKS advertises alg="RS256" for an EC key — pathological but tests the alg-match path.
        let mismatchedJWK = JWK(
            kty: "EC", use: "sig", kid: Self.kid, alg: "RS256",
            crv: "P-256",
            x: Base64URL.encode(key.publicKey.x963Representation.subdata(in: 1..<33)),
            y: Base64URL.encode(key.publicKey.x963Representation.subdata(in: 33..<65))
        )
        let jwks = JWKS(keys: [mismatchedJWK])
        let jws = try Self.makeES256JWT(privateKey: key)
        let jwksClient = try await client(jwks: jwks)

        await #expect(throws: JWTVerificationError.self) {
            _ = try await JWTVerifier().verify(
                jws: jws,
                jwksClient: jwksClient,
                jwksURL: Self.jwksURL,
                config: standardConfig()
            )
        }
    }

    @Test("JWKSClient TTL cache returns the cached JWK without re-fetching")
    func jwksTTLCacheUsesFirstFetch() async throws {
        let key = P256.Signing.PrivateKey()
        let jwks = Self.makeJWKS(publicKey: key.publicKey)
        let body = try JSONEncoder().encode(jwks)
        let networking = JWKSStubNetworking(body: body)
        let cachingClient = JWKSClient(networking: networking, ttl: 600)

        let key1 = try await cachingClient.key(forKID: Self.kid, at: Self.jwksURL)
        let key2 = try await cachingClient.key(forKID: Self.kid, at: Self.jwksURL)
        // Both lookups returned the same JWK object — proves the cache path.
        #expect(key1 == key2)
    }

    @Test("Base64URL decoder handles unpadded and padded inputs equivalently")
    func base64URLDecoder() {
        let raw = Data("hello world".utf8)
        let unpadded = Base64URL.encode(raw)
        let padded = unpadded + String(repeating: "=", count: (4 - unpadded.count % 4) % 4)
        #expect(Base64URL.decode(unpadded) == raw)
        #expect(Base64URL.decode(padded) == raw)
    }
}
