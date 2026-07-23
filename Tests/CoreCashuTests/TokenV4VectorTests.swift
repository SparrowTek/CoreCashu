//
//  TokenV4VectorTests.swift
//  CoreCashu
//
//  Decodes the official NUT-00 V4 (`cashuB`) test vectors — byte-for-byte tokens as
//  emitted by cdk/nutshell — and round-trips our own encoding. Guards against the
//  JSON-bridged CBOR regression that (a) crashed the process on any real V4 token
//  (byte strings fed to JSONSerialization) and (b) emitted base64 text where the spec
//  requires CBOR byte strings.
//

import Testing
import Foundation
@testable import CoreCashu

@Suite("NUT-00 V4 token vectors")
struct TokenV4VectorTests {

    private let singleKeysetVector = "cashuBpGF0gaJhaUgArSaMTR9YJmFwgaNhYQFhc3hAOWE2ZGJiODQ3YmQyMzJiYTc2ZGIwZGYxOTcyMTZiMjlkM2I4Y2MxNDU1M2NkMjc4MjdmYzFjYzk0MmZlZGI0ZWFjWCEDhhhUP_trhpXfStS6vN6So0qWvc2X3O4NfM-Y1HISZ5JhZGlUaGFuayB5b3VhbXVodHRwOi8vbG9jYWxob3N0OjMzMzhhdWNzYXQ="

    private let multiKeysetVector = "cashuBo2F0gqJhaUgA_9SLj17PgGFwgaNhYQFhc3hAYWNjMTI0MzVlN2I4NDg0YzNjZjE4NTAxNDkyMThhZjkwZjcxNmE1MmJmNGE1ZWQzNDdlNDhlY2MxM2Y3NzM4OGFjWCECRFODGd5IXVW-07KaZCvuWHk3WrnnpiDhHki6SCQh88-iYWlIAK0mjE0fWCZhcIKjYWECYXN4QDEzMjNkM2Q0NzA3YTU4YWQyZTIzYWRhNGU5ZjFmNDlmNWE1YjRhYzdiNzA4ZWIwZDYxZjczOGY0ODMwN2U4ZWVhY1ghAjRWqhENhLSsdHrr2Cw7AFrKUL9Ffr1XN6RBT6w659lNo2FhAWFzeEA1NmJjYmNiYjdjYzY0MDZiM2ZhNWQ1N2QyMTc0ZjRlZmY4YjQ0MDJiMTc2OTI2ZDNhNTdkM2MzZGNiYjU5ZDU3YWNYIQJzEpxXGeWZN5qXSmJjY8MzxWyvwObQGr5G1YCCgHicY2FtdWh0dHA6Ly9sb2NhbGhvc3Q6MzMzOGF1Y3NhdA"

    @Test("Official single-keyset vector decodes")
    func singleKeysetVectorDecodes() throws {
        let token = try CashuTokenUtils.deserializeToken(singleKeysetVector)

        #expect(token.unit == "sat")
        #expect(token.memo == "Thank you")
        #expect(token.token.count == 1)
        #expect(token.token.first?.mint == "http://localhost:3338")

        let proofs = try #require(token.token.first?.proofs)
        #expect(proofs.count == 1)
        let proof = try #require(proofs.first)
        #expect(proof.amount == 1)
        #expect(proof.id == "00ad268c4d1f5826")
        #expect(proof.secret == "9a6dbb847bd232ba76db0df197216b29d3b8cc14553cd27827fc1cc942fedb4e")
        #expect(proof.C == "038618543ffb6b8695df4ad4babcde92a34a96bdcd97dcee0d7ccf98d472126792")
    }

    @Test("Official multi-keyset vector decodes")
    func multiKeysetVectorDecodes() throws {
        let token = try CashuTokenUtils.deserializeToken(multiKeysetVector)

        #expect(token.unit == "sat")
        #expect(token.memo == nil)
        #expect(token.token.first?.mint == "http://localhost:3338")

        let proofs = try #require(token.token.first?.proofs)
        #expect(proofs.count == 3)
        #expect(proofs.reduce(0) { $0 + $1.amount } == 4)

        let keysetIDs = Set(proofs.map { $0.id })
        #expect(keysetIDs == ["00ffd48b8f5ecf80", "00ad268c4d1f5826"])

        let two = try #require(proofs.first { $0.amount == 2 })
        #expect(two.id == "00ad268c4d1f5826")
        #expect(two.secret == "1323d3d4707a58ad2e23ada4e9f1f49f5a5b4ac7b708eb0d61f738f48307e8ee")
        #expect(two.C == "023456aa110d84b4ac747aebd82c3b005aca50bf457ebd5737a4414fac3ae7d94d")
    }

    @Test("V4 round-trip preserves proofs, DLEQ, and witness")
    func roundTripPreservesEverything() throws {
        let proof = Proof(
            amount: 8,
            id: "00ad268c4d1f5826",
            secret: "9a6dbb847bd232ba76db0df197216b29d3b8cc14553cd27827fc1cc942fedb4e",
            C: "038618543ffb6b8695df4ad4babcde92a34a96bdcd97dcee0d7ccf98d472126792",
            witness: "{\"signatures\":[\"ab\"]}",
            dleq: DLEQProof(
                e: "9818e061ee51d5c8edc3342369a554998ff7b4381c8652d724cdf46429be73d9",
                s: "9818e061ee51d5c8edc3342369a554998ff7b4381c8652d724cdf46429be73da",
                r: "9818e061ee51d5c8edc3342369a554998ff7b4381c8652d724cdf46429be73db"
            )
        )
        let token = CashuToken(
            token: [TokenEntry(mint: "https://mint.example.com", proofs: [proof])],
            unit: "sat",
            memo: "round trip"
        )

        let serialized = try CashuTokenUtils.serializeTokenV4(token)
        let decoded = try CashuTokenUtils.deserializeToken(serialized)

        let restored = try #require(decoded.token.first?.proofs.first)
        #expect(restored.amount == proof.amount)
        #expect(restored.id == proof.id)
        #expect(restored.secret == proof.secret)
        #expect(restored.C == proof.C)
        #expect(restored.witness == proof.witness)
        #expect(restored.dleq?.e == proof.dleq?.e)
        #expect(restored.dleq?.s == proof.dleq?.s)
        #expect(restored.dleq?.r == proof.dleq?.r)
        #expect(decoded.unit == "sat")
        #expect(decoded.memo == "round trip")
        #expect(decoded.token.first?.mint == "https://mint.example.com")
    }

    @Test("Encoded V4 token uses CBOR byte strings for id and signature")
    func encodedTokenUsesByteStrings() throws {
        let proof = Proof(
            amount: 1,
            id: "00ad268c4d1f5826",
            secret: "secret",
            C: "038618543ffb6b8695df4ad4babcde92a34a96bdcd97dcee0d7ccf98d472126792"
        )
        let token = CashuToken(token: [TokenEntry(mint: "http://localhost:3338", proofs: [proof])], unit: "sat")

        let serialized = try CashuTokenUtils.serializeTokenV4(token)
        var base64 = String(serialized.dropFirst("cashuB".count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        let cborBytes = [UInt8](try #require(Data(base64Encoded: base64)))

        // The 8-byte keyset ID must appear as a CBOR byte string: major type 2, length 8
        // (0x48) followed by the raw bytes — not as base64 text.
        let keysetBytes: [UInt8] = [0x48, 0x00, 0xAD, 0x26, 0x8C, 0x4D, 0x1F, 0x58, 0x26]
        #expect(containsSubsequence(cborBytes, keysetBytes))

        // The 33-byte signature: major type 2 with one-byte length (0x58 0x21).
        let sigPrefix: [UInt8] = [0x58, 0x21, 0x03, 0x86, 0x18, 0x54]
        #expect(containsSubsequence(cborBytes, sigPrefix))
    }

    @Test("Malformed cashuB input throws instead of crashing")
    func malformedInputThrows() {
        // Structurally valid CBOR that is not a token (byte strings in odd places), plus
        // outright garbage — all must throw CashuError, never crash.
        let bad = [
            "cashuB" + Data([0xA1, 0x61, 0x6D, 0x42, 0xDE, 0xAD]).base64EncodedString(), // {"m": h'DEAD'}
            "cashuB" + Data([0x42, 0xDE, 0xAD]).base64EncodedString(),                   // bare byte string
            "cashuBnot-base64!!!",
            "cashuB",
        ]
        for input in bad {
            #expect(throws: (any Error).self) {
                _ = try CashuTokenUtils.deserializeToken(input)
            }
        }
    }

    @Test("Serializing a multi-mint token as V4 is refused")
    func multiMintRefused() {
        let proof = Proof(amount: 1, id: "00ad268c4d1f5826", secret: "s", C: "02aa")
        let token = CashuToken(
            token: [
                TokenEntry(mint: "https://a.example.com", proofs: [proof]),
                TokenEntry(mint: "https://b.example.com", proofs: [proof]),
            ],
            unit: "sat"
        )
        #expect(throws: (any Error).self) {
            _ = try CashuTokenUtils.serializeTokenV4(token)
        }
    }

    private func containsSubsequence(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        return (0...(haystack.count - needle.count)).contains { offset in
            Array(haystack[offset..<offset + needle.count]) == needle
        }
    }
}
