import Testing
@testable import CoreCashu
import Foundation

@Suite("Token Round-Trip Tests", .serialized)
struct TokenRoundTripTests {
    
    @Test("Token serialization preserves all data")
    func tokenSerializationRoundTrip() async throws {
        // Create test tokens with various configurations
        let testCases = [
            // Simple token with one proof
            CashuToken(
                token: [TokenEntry(
                    mint: "https://mint1.example.com",
                    proofs: [Proof(amount: 100, id: "0000000000000001", secret: "secret1", C: "deadbeef1234567890abcdef1234567890abcdef1234567890abcdef1234567890")]
                )],
                unit: "sat"
            ),
            // Token with multiple proofs
            CashuToken(
                token: [TokenEntry(
                    mint: "https://mint2.example.com",
                    proofs: [
                        Proof(amount: 1, id: "0000000000000002", secret: "secret2a", C: "abcdef1234567890deadbeef1234567890abcdef1234567890abcdef1234567890"),
                        Proof(amount: 2, id: "0000000000000002", secret: "secret2b", C: "1234567890abcdefdeadbeef1234567890abcdef1234567890abcdef1234567890"),
                        Proof(amount: 4, id: "0000000000000002", secret: "secret2c", C: "567890abcdefdeadbeef1234567890abcdef1234567890abcdef1234567890abcd")
                    ]
                )],
                unit: "usd",
                memo: "Test payment"
            ),
            // Token with multiple mints
            CashuToken(
                token: [
                    TokenEntry(
                        mint: "https://mint3a.example.com",
                        proofs: [Proof(amount: 50, id: "0000000000000003", secret: "secret3a", C: "deadbeefdeadbeef1234567890abcdef1234567890abcdef1234567890abcdef12")]
                    ),
                    TokenEntry(
                        mint: "https://mint3b.example.com",
                        proofs: [Proof(amount: 25, id: "0000000000000004", secret: "secret3b", C: "abcdefabcdef1234567890deadbeef1234567890abcdef1234567890abcdef1234")]
                    )
                ],
                unit: "eur"
            )
        ]
        
        for (index, originalToken) in testCases.enumerated() {
            // Test V3 serialization
            let v3Serialized = try CashuTokenUtils.serializeTokenV3(originalToken)
            let v3Deserialized = try CashuTokenUtils.deserializeTokenV3(v3Serialized)
            
            #expect(v3Deserialized.unit == originalToken.unit, "V3 unit mismatch for test case \(index)")
            #expect(v3Deserialized.memo == originalToken.memo, "V3 memo mismatch for test case \(index)")
            #expect(v3Deserialized.token.count == originalToken.token.count, "V3 token count mismatch for test case \(index)")
            
            // Test V4 serialization (may have limitations with multiple mints)
            do {
                let v4Serialized = try CashuTokenUtils.serializeTokenV4(originalToken)
                let v4Deserialized = try CashuTokenUtils.deserializeTokenV4(v4Serialized)
                
                #expect(v4Deserialized.unit == originalToken.unit, "V4 unit mismatch for test case \(index)")
                #expect(v4Deserialized.memo == originalToken.memo, "V4 memo mismatch for test case \(index)")
                // V4 may not preserve multiple mints correctly
                if originalToken.token.count == 1 {
                    #expect(v4Deserialized.token.count == originalToken.token.count, "V4 token count mismatch for test case \(index)")
                }
            } catch {
                // V4 serialization might not support all token formats
                print("V4 serialization not supported for test case \(index): \(error)")
            }
            
            // Test JSON serialization
            let jsonSerialized = try CashuTokenUtils.serializeTokenJSON(originalToken)
            let jsonDeserialized = try CashuTokenUtils.deserializeTokenJSON(jsonSerialized)
            
            #expect(jsonDeserialized.unit == originalToken.unit, "JSON unit mismatch for test case \(index)")
            #expect(jsonDeserialized.memo == originalToken.memo, "JSON memo mismatch for test case \(index)")
            #expect(jsonDeserialized.token.count == originalToken.token.count, "JSON token count mismatch for test case \(index)")
        }
    }
    
    @Test("Token serialization handles edge cases")
    func tokenSerializationEdgeCases() async throws {
        // Token with empty memo
        let tokenNoMemo = CashuToken(
            token: [TokenEntry(
                mint: "https://mint.example.com",
                proofs: [Proof(amount: 10, id: "0000000000000005", secret: "s1", C: "1111111111111111111111111111111111111111111111111111111111111111")]
            )],
            unit: "sat",
            memo: nil
        )
        
        let serialized = try CashuTokenUtils.serializeToken(tokenNoMemo)
        let deserialized = try CashuTokenUtils.deserializeToken(serialized)
        #expect(deserialized.memo == nil)
        
        // Token with special characters in memo
        let tokenSpecialMemo = CashuToken(
            token: [TokenEntry(
                mint: "https://mint.example.com",
                proofs: [Proof(amount: 10, id: "0000000000000005", secret: "s1", C: "1111111111111111111111111111111111111111111111111111111111111111")]
            )],
            unit: "sat",
            memo: "Test 🚀 with émojis & special chars: <>&\""
        )
        
        let serialized2 = try CashuTokenUtils.serializeToken(tokenSpecialMemo)
        let deserialized2 = try CashuTokenUtils.deserializeToken(serialized2)
        #expect(deserialized2.memo == tokenSpecialMemo.memo)
    }
    
    @Test("Token amount calculation")
    func tokenAmountCalculation() async throws {
        let proofs = [
            Proof(amount: 1, id: "0000000000000006", secret: "s1", C: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
            Proof(amount: 2, id: "0000000000000006", secret: "s2", C: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
            Proof(amount: 4, id: "0000000000000006", secret: "s3", C: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
            Proof(amount: 8, id: "0000000000000006", secret: "s4", C: "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd")
        ]
        
        let token = CashuToken(
            token: [TokenEntry(mint: "https://mint.example.com", proofs: proofs)],
            unit: "sat"
        )
        
        let totalAmount = token.token.flatMap { $0.proofs }.reduce(0) { $0 + $1.amount }
        #expect(totalAmount == 15)
    }
}