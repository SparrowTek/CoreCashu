import Foundation
import Testing
@testable import CoreCashu

@Suite("Key Generation Property Tests")
struct KeyGenerationPropertyTests {
    @Test
    func secretsHaveExpectedShape() throws {
        for _ in 0..<64 {
            let secretHex = try CashuKeyUtils.generateRandomSecret()
            #expect(secretHex.count == 64, "Secret should be 64 hex characters")
            #expect(secretHex.allSatisfy { $0.isHexDigit }, "Secret must be valid hex")

            guard let secretData = Data(hexString: secretHex) else {
                #expect(Bool(false), "Secret failed hex decoding")
                continue
            }

            #expect(secretData.count == 32, "Decoded secret should be 32 bytes")
            #expect(secretData.contains { $0 != 0 }, "Secret should not be all zeros")
        }
    }

    @Test
    func secretsDoNotCollideInSample() throws {
        var generated: Set<String> = []
        for _ in 0..<256 {
            let secret = try CashuKeyUtils.generateRandomSecret()
            let inserted = generated.insert(secret).inserted
            #expect(inserted, "Duplicate secret generated: \(secret)")
        }
    }
}
