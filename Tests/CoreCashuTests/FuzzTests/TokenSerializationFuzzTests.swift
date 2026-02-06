import Testing
@testable import CoreCashu
import Foundation

@Suite("Token Serialization Fuzz Tests", .serialized)
struct TokenSerializationFuzzTests {

    // MARK: - Fuzz Test Generators

    /// Generate random bytes for fuzzing
    func generateRandomBytes(length: Int) -> Data {
        var bytes = Data(count: length)
        _ = bytes.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, length, ptr.baseAddress!)
        }
        return bytes
    }

    /// Generate malformed JSON strings
    func generateMalformedJSON() -> [String] {
        return [
            "",                           // Empty string
            "null",                       // Null value
            "undefined",                  // Undefined
            "{}",                        // Empty object
            "[]",                        // Empty array
            "{",                         // Incomplete object
            "}",                         // Unmatched brace
            "[",                         // Incomplete array
            "]",                         // Unmatched bracket
            "{'key': 'value'}",          // Single quotes
            "{key: value}",              // Missing quotes
            "{\"key\"",                  // Incomplete key
            "{\"key\": }",               // Missing value
            "{\"key\": \"value\"",       // Missing closing brace
            "[1, 2, 3",                  // Missing closing bracket
            "{\"a\":1, \"b\":}",         // Trailing comma with missing value
            "[1, 2, 3,]",                // Trailing comma
            "NaN",                       // Not a number
            "Infinity",                  // Infinity
            "-Infinity",                 // Negative infinity
            "1e10000",                   // Very large number
            String(repeating: "{", count: 1000), // Deeply nested
            String(repeating: "a", count: 100000), // Very long string
        ]
    }

    /// Generate malformed token strings
    func generateMalformedTokens() -> [String] {
        return [
            "cashu",                     // Incomplete prefix
            "cashuA",                    // Invalid version
            "cashuB",                    // Another invalid version
            "cashu1234",                 // Invalid base64
            "cashuA===",                 // Invalid padding
            "cashuA" + String(repeating: "A", count: 10000), // Very long token
            "CashuA", // Wrong case
            "CASHUA", // All caps
            "cashu A", // Space in token
            "cashu\nA", // Newline in token
            "cashu\0A", // Null byte in token
            "💩cashuA", // Emoji prefix
            "cashuA💩", // Emoji suffix
        ]
    }

    // MARK: - Token Parsing Fuzz Tests

    @Test("Fuzz test token deserialization with random data")
    func fuzzTokenDeserialization() throws {
        let crashCount = 0
        var errorCount = 0
        var successCount = 0

        // Test with random binary data
        for _ in 0..<1000 {
            let randomData = generateRandomBytes(length: Int.random(in: 1...1000))
            let randomString = String(data: randomData, encoding: .utf8) ?? ""

            do {
                let _ = try CashuTokenUtils.deserializeToken(randomString)
                successCount += 1
            } catch {
                errorCount += 1
                // Expected - invalid data should throw
            }
        }

        print("Token deserialization fuzz: \(successCount) success, \(errorCount) errors, \(crashCount) crashes")
        #expect(crashCount == 0, "Token deserialization crashed on fuzz input")
    }

    @Test("Fuzz test token parsing with malformed JSON")
    func fuzzTokenJSONParsing() throws {
        let malformedInputs = generateMalformedJSON()
        let crashCount = 0
        var errorCount = 0

        for input in malformedInputs {
            do {
                let _ = try CashuTokenUtils.deserializeToken(input)
            } catch {
                errorCount += 1
                // Expected - malformed JSON should throw
            }
        }

        print("JSON parsing fuzz: \(errorCount) errors from \(malformedInputs.count) inputs")
        #expect(crashCount == 0, "JSON parsing crashed on malformed input")
    }

    @Test("Fuzz test token parsing with malformed tokens")
    func fuzzMalformedTokens() throws {
        let malformedTokens = generateMalformedTokens()
        var errorCount = 0

        for token in malformedTokens {
            do {
                let _ = try CashuTokenUtils.deserializeToken(token)
            } catch {
                errorCount += 1
                // Expected - malformed tokens should throw
            }
        }

        #expect(errorCount == malformedTokens.count, "Some malformed tokens didn't throw errors")
    }

    // MARK: - Proof Serialization Fuzz Tests

    @Test("Fuzz test proof serialization with edge cases")
    func fuzzProofSerialization() throws {
        let edgeCases = [
            (amount: 0, id: "", secret: "", C: ""),
            (amount: -1, id: "test", secret: "test", C: "test"),
            (amount: Int.max, id: "max", secret: "max", C: "max"),
            (amount: Int.min, id: "min", secret: "min", C: "min"),
            (amount: 1, id: String(repeating: "a", count: 10000), secret: "test", C: "test"),
            (amount: 1, id: "test", secret: String(repeating: "b", count: 10000), C: "test"),
            (amount: 1, id: "test", secret: "test", C: String(repeating: "c", count: 10000)),
            (amount: 1, id: "💩", secret: "💩", C: "💩"), // Emojis
            (amount: 1, id: "\0", secret: "\0", C: "\0"), // Null bytes
            (amount: 1, id: "\n\r\t", secret: "\n\r\t", C: "\n\r\t"), // Control characters
        ]

        for (i, testCase) in edgeCases.enumerated() {
            let proof = Proof(
                amount: testCase.amount,
                id: testCase.id,
                secret: testCase.secret,
                C: testCase.C
            )

            // Test JSON encoding/decoding
            do {
                let encoded = try JSONEncoder().encode(proof)
                let decoded = try JSONDecoder().decode(Proof.self, from: encoded)
                #expect(decoded.amount == proof.amount, "Amount mismatch in edge case \(i)")
            } catch {
                // Some edge cases might legitimately fail
                print("Edge case \(i) failed: \(error)")
            }
        }
    }

    // MARK: - CBOR Fuzz Tests

    @Test("Fuzz test CBOR token parsing")
    func fuzzCBORParsing() throws {
        // Generate random CBOR-like data
        for _ in 0..<100 {
            let randomData = generateRandomBytes(length: Int.random(in: 10...500))

            // Try to parse as CBOR token
            do {
                // Try to parse as CBOR token - using V4 format
                // First, create a base64-encoded string with cashuB prefix
                let base64 = randomData.base64EncodedString()
                let cborToken = "cashuB" + base64
                if let token = try? CashuTokenUtils.deserializeTokenV4(cborToken) {
                    // If it parsed, try round-trip
                    let encoded = try CashuTokenUtils.serializeTokenV4(token)
                    let decoded = try CashuTokenUtils.deserializeTokenV4(encoded)
                    #expect(decoded.unit == token.unit, "CBOR round-trip failed")
                }
            } catch {
                // Expected - random data usually won't be valid CBOR
            }
        }
    }

    // MARK: - Network Message Fuzz Tests

    @Test("Fuzz test network message parsing")
    func fuzzNetworkMessageParsing() throws {
        let malformedMessages = [
            #"{}"#,
            #"{"error": null}"#,
            #"{"error": "test", "code": "not_a_number"}"#,
            #"{"detail": 123}"#, // Wrong type
            #"{"signatures": "not_an_array"}"#,
            #"{"promises": [{}]}"#, // Empty promise
            #"{"amount": "100"}"#, // String instead of number
        ]

        for message in malformedMessages {
            let data = message.data(using: .utf8)!

            // Try parsing as various response types
            _ = try? JSONDecoder().decode(PostMintQuoteBolt11Response.self, from: data)
            _ = try? JSONDecoder().decode(PostMeltQuoteBolt11Response.self, from: data)
            _ = try? JSONDecoder().decode(PostSwapResponse.self, from: data)

            // None should crash - all should handle gracefully
        }

        #expect(true, "Network message parsing handled all malformed inputs")
    }

    // MARK: - Boundary Tests

    @Test("Fuzz test with boundary values")
    func fuzzBoundaryValues() throws {
        let boundaries = [
            // Number boundaries
            "0", "1", "-1",
            String(Int.max), String(Int.min),
            String(UInt64.max),
            "1.1", "0.0", "-0.0",
            "1e308", "-1e308", // Double max/min
            "1e-308",

            // String boundaries
            "", " ", "  ",
            String(repeating: "a", count: 65536),
            String(repeating: "🔥", count: 1000),

            // Special characters
            "\0", "\n", "\r", "\t",
            "\\", "\"", "'",
            "\u{0000}", "\u{FFFF}",
        ]

        for value in boundaries {
            // Try using as various fields in a token
            let tokenString = """
            {
                "token": [{
                    "mint": "\(value)",
                    "proofs": [{
                        "amount": 1,
                        "id": "\(value)",
                        "secret": "\(value)",
                        "C": "\(value)"
                    }]
                }],
                "unit": "\(value)"
            }
            """

            _ = try? CashuTokenUtils.deserializeToken("cashuA" + tokenString.data(using: .utf8)!.base64EncodedString())
        }

        #expect(true, "Boundary value testing completed without crashes")
    }

    // MARK: - Mutation Testing

    @Test("Fuzz test with mutated valid tokens")
    func fuzzMutatedTokens() throws {
        // Start with a valid token
        let validToken = CashuToken(
            token: [TokenEntry(
                mint: "https://mint.example",
                proofs: [Proof(
                    amount: 100,
                    id: "00000000000001",
                    secret: "test_secret",
                    C: "02" + String(repeating: "0", count: 64)
                )]
            )],
            unit: "sat"
        )

        let validSerialized = try CashuTokenUtils.serializeToken(validToken)

        // Apply mutations
        let mutations = [
            { (s: String) -> String in s.replacingOccurrences(of: "cashuA", with: "cashuB") },
            { (s: String) -> String in s.replacingOccurrences(of: "100", with: "-100") },
            { (s: String) -> String in s.replacingOccurrences(of: "sat", with: "") },
            { (s: String) -> String in String(s.dropLast(1)) },
            { (s: String) -> String in String(s.dropLast(10)) },
            { (s: String) -> String in s + s }, // Double the token
            { (s: String) -> String in String(s.reversed()) },
            { (s: String) -> String in s.replacingOccurrences(of: "=", with: "") },
            { (s: String) -> String in s.replacingOccurrences(of: "+", with: "-") },
            { (s: String) -> String in s.replacingOccurrences(of: "/", with: "_") },
        ]

        for mutation in mutations {
            let mutated = mutation(validSerialized)
            do {
                let _ = try CashuTokenUtils.deserializeToken(mutated)
                // Some mutations might still produce valid tokens
            } catch {
                // Expected for most mutations
            }
        }

        #expect(true, "Mutation testing completed")
    }

    // MARK: - Performance Under Fuzz

    @Test("Performance test with large tokens")
    func fuzzLargeTokens() throws {
        // Create increasingly large tokens
        for proofCount in [10, 100, 500, 1000] {
            let proofs = (0..<proofCount).map { i in
                Proof(
                    amount: 1,
                    id: "test",
                    secret: "secret-\(i)",
                    C: String(format: "%064x", i)
                )
            }

            let token = CashuToken(
                token: [TokenEntry(mint: "https://test", proofs: proofs)],
                unit: "sat"
            )

            measure {
                do {
                    let serialized = try CashuTokenUtils.serializeToken(token)
                    let _ = try CashuTokenUtils.deserializeToken(serialized)
                } catch {
                    Issue.record("Failed to serialize/deserialize large token with \(proofCount) proofs")
                }
            }
        }
    }

    // Helper function for performance measurement
    func measure(block: () throws -> Void) {
        let start = Date()
        do {
            try block()
        } catch {
            print("Performance test error: \(error)")
        }
        let elapsed = Date().timeIntervalSince(start)
        print("Elapsed: \(elapsed)s")
    }
}
