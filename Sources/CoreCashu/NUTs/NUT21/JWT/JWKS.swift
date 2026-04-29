//
//  JWKS.swift
//  CoreCashu
//
//  NUT-21: Clear authentication — JSON Web Key Set models and TTL-cached fetcher.
//  Phase 8.1 (2026-04-29).
//

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A single JSON Web Key (RFC 7517).
///
/// Only the fields CoreCashu needs for ES256 / RS256 signature verification are modelled here;
/// other JWK members are accepted by the decoder and ignored.
public struct JWK: Codable, Sendable, Equatable {
    /// Key type — `"EC"` or `"RSA"`.
    public let kty: String
    /// Public-key use (e.g. `"sig"`).
    public let use: String?
    /// Key ID — the `kid` header in a JWS picks a key by this value.
    public let kid: String?
    /// Algorithm bound to this key — when present, MUST match the JWS header `alg`.
    public let alg: String?

    // EC fields (ES256 → P-256)
    /// Curve name for EC keys (e.g. `"P-256"`).
    public let crv: String?
    /// Base64url-encoded X coordinate.
    public let x: String?
    /// Base64url-encoded Y coordinate.
    public let y: String?

    // RSA fields (RS256)
    /// Base64url-encoded RSA modulus.
    public let n: String?
    /// Base64url-encoded RSA public exponent.
    public let e: String?

    public init(
        kty: String,
        use: String? = nil,
        kid: String? = nil,
        alg: String? = nil,
        crv: String? = nil,
        x: String? = nil,
        y: String? = nil,
        n: String? = nil,
        e: String? = nil
    ) {
        self.kty = kty
        self.use = use
        self.kid = kid
        self.alg = alg
        self.crv = crv
        self.x = x
        self.y = y
        self.n = n
        self.e = e
    }
}

/// A JWKS document — `{ "keys": [JWK, ...] }` per RFC 7517 §5.
public struct JWKS: Codable, Sendable, Equatable {
    public let keys: [JWK]

    public init(keys: [JWK]) { self.keys = keys }

    /// Return the JWK matching the supplied `kid`, or `nil` if not found.
    public func key(forKID kid: String) -> JWK? {
        keys.first { $0.kid == kid }
    }
}

// MARK: - JWKS client

/// Fetches JWKS documents over HTTPS with a per-URI TTL cache.
///
/// Each `JWKSClient` instance is independent; the cache is in-memory and process-local. Use a
/// single instance per wallet so concurrent JWT verifications share the cache.
public actor JWKSClient {
    /// How long a fetched JWKS is considered fresh before re-fetching.
    public let ttl: TimeInterval
    private let networking: any Networking
    private var cache: [String: CachedEntry] = [:]

    private struct CachedEntry: Sendable {
        let jwks: JWKS
        let fetchedAt: Date
    }

    public init(networking: any Networking, ttl: TimeInterval = 600) {
        self.networking = networking
        self.ttl = ttl
    }

    /// Look up a JWK by `kid` in the cached or freshly-fetched JWKS at `jwksURL`. If the cache
    /// is fresh and contains the `kid`, that entry is returned without a network round-trip.
    /// Otherwise the JWKS is re-fetched and looked up; a still-missing `kid` throws.
    public func key(forKID kid: String, at jwksURL: URL) async throws -> JWK {
        let urlKey = jwksURL.absoluteString

        if let entry = cache[urlKey],
           Date().timeIntervalSince(entry.fetchedAt) < ttl,
           let key = entry.jwks.key(forKID: kid) {
            return key
        }

        let jwks = try await fetchJWKS(at: jwksURL)
        cache[urlKey] = CachedEntry(jwks: jwks, fetchedAt: Date())

        guard let key = jwks.key(forKID: kid) else {
            throw CashuError.clearAuthFailed("JWKS at \(jwksURL.absoluteString) does not contain key id '\(kid)'")
        }
        return key
    }

    /// Force-refresh the cache for a given URL. Intended for tests; production code should rely
    /// on the TTL.
    public func invalidate(_ jwksURL: URL) {
        cache.removeValue(forKey: jwksURL.absoluteString)
    }

    private func fetchJWKS(at jwksURL: URL) async throws -> JWKS {
        var request = URLRequest(url: jwksURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await networking.data(for: request, delegate: nil)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CashuError.clearAuthFailed("JWKS fetch returned a non-HTTP response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw CashuError.clearAuthFailed("JWKS fetch failed with status \(httpResponse.statusCode)")
        }

        do {
            return try JSONDecoder().decode(JWKS.self, from: data)
        } catch {
            throw CashuError.clearAuthFailed("JWKS document was not valid JSON: \(error.localizedDescription)")
        }
    }
}
