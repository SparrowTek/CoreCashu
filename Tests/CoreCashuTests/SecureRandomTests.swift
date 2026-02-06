import Foundation
import Testing
@testable import CoreCashu

@Suite("SecureRandom overrides", .serialized)
struct SecureRandomTests {
    @Test
    func defaultGeneratorProducesRequestedLength() throws {
        let bytes = try SecureRandom.generateBytes(count: 16)
        #expect(bytes.count == 16)
    }

    @Test
    func scopedGeneratorOverridesDefault() throws {
        let bytes = try SecureRandom.withGenerator({ count in
            Data(repeating: 0xAB, count: count)
        }) {
            try SecureRandom.generateBytes(count: 8)
        }

        #expect(bytes == Data(repeating: 0xAB, count: 8))
    }

    @Test
    func scopedGeneratorDoesNotLeakOutsideScope() throws {
        let sentinel = try SecureRandom.withGenerator({ count in
            Data(repeating: 0xEE, count: count)
        }) {
            try SecureRandom.generateBytes(count: 3)
        }

        #expect(sentinel == Data(repeating: 0xEE, count: 3))
        let bytes = try SecureRandom.generateBytes(count: 32)
        #expect(bytes.count == 32)
        #expect(!bytes.allSatisfy { $0 == 0xEE }, "Platform generator should produce non-sentinel output")
    }
}
