import Foundation
import Testing
@testable import CoreCashu

@Suite("SecureRandom overrides")
struct SecureRandomTests {
    @Test
    func defaultGeneratorProducesRequestedLength() throws {
        SecureRandom.resetGenerator()
        let bytes = try SecureRandom.generateBytes(count: 16)
        #expect(bytes.count == 16)
    }

    @Test
    func customGeneratorOverridesDefault() throws {
        defer { SecureRandom.resetGenerator() }
        SecureRandom.installGenerator { count in
            Data(repeating: 0xAB, count: count)
        }
        
        let bytes = try SecureRandom.generateBytes(count: 8)
        #expect(bytes == Data(repeating: 0xAB, count: 8))
    }

    @Test
    func resettingRestoresPlatformGenerator() throws {
        SecureRandom.installGenerator { count in
            Data(repeating: 0xEE, count: count)
        }
        let sentinel = try SecureRandom.generateBytes(count: 3)
        #expect(sentinel == Data(repeating: 0xEE, count: 3))
        SecureRandom.resetGenerator()
        
        let bytes = try SecureRandom.generateBytes(count: 32)
        #expect(bytes.count == 32)
        #expect(!bytes.allSatisfy { $0 == 0xEE }, "Platform generator should produce non-sentinel output")
    }
}
