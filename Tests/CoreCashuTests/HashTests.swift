import Testing
@testable import CoreCashu
import Foundation

/// Tests for the cross-platform `Hash` module that replaces direct `CryptoKit` usage in
/// CoreCashu. Vectors below are NIST/RFC published test vectors so we can be confident the
/// CryptoSwift backend is wired correctly before swapping callers.
@Suite("Hash module — cross-platform crypto primitives")
struct HashTests {

    // MARK: - SHA-256 vectors (NIST FIPS 180-4 examples)

    @Test("SHA-256 of empty input")
    func testSHA256Empty() {
        let digest = Hash.sha256(Data())
        #expect(digest.hexString == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("SHA-256 of \"abc\"")
    func testSHA256Abc() {
        let digest = Hash.sha256(Data("abc".utf8))
        #expect(digest.hexString == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("SHA-256 of long input")
    func testSHA256LongInput() {
        let input = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
        let digest = Hash.sha256(Data(input.utf8))
        #expect(digest.hexString == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    // MARK: - SHA-512 vectors (NIST FIPS 180-4 examples)

    @Test("SHA-512 of empty input")
    func testSHA512Empty() {
        let digest = Hash.sha512(Data())
        let expected =
            "cf83e1357eefb8bdf1542850d66d8007" +
            "d620e4050b5715dc83f4a921d36ce9ce" +
            "47d0d13c5d85f2b0ff8318d2877eec2f" +
            "63b931bd47417a81a538327af927da3e"
        #expect(digest.hexString == expected)
    }

    @Test("SHA-512 of \"abc\"")
    func testSHA512Abc() {
        let digest = Hash.sha512(Data("abc".utf8))
        let expected =
            "ddaf35a193617abacc417349ae204131" +
            "12e6fa4e89a97ea20a9eeee64b55d39a" +
            "2192992a274fc1a836ba3c23a3feebbd" +
            "454d4423643ce80e2a9ac94fa54ca49f"
        #expect(digest.hexString == expected)
    }

    // MARK: - HMAC-SHA-512 vectors (RFC 4231)

    @Test("HMAC-SHA-512 RFC 4231 test case 1")
    func testHMACSHA512_RFC4231_TestCase1() {
        // key = 0x0b * 20, data = "Hi There"
        let key = Data(repeating: 0x0b, count: 20)
        let data = Data("Hi There".utf8)
        let mac = Hash.hmacSHA512(key: key, data: data)
        let expected =
            "87aa7cdea5ef619d4ff0b4241a1d6cb0" +
            "2379f4e2ce4ec2787ad0b30545e17cde" +
            "daa833b7d6b8a702038b274eaea3f4e4" +
            "be9d914eeb61f1702e696c203a126854"
        #expect(mac.hexString == expected)
    }

    @Test("HMAC-SHA-512 RFC 4231 test case 2")
    func testHMACSHA512_RFC4231_TestCase2() {
        // key = "Jefe" (4 bytes), data = "what do ya want for nothing?"
        let key = Data("Jefe".utf8)
        let data = Data("what do ya want for nothing?".utf8)
        let mac = Hash.hmacSHA512(key: key, data: data)
        let expected =
            "164b7a7bfcf819e2e395fbe73b56e0a3" +
            "87bd64222e831fd610270cd7ea250554" +
            "9758bf75c05a994a6d034f65f8f0e6fd" +
            "caeab1a34d4a6b4b636e070a38bce737"
        #expect(mac.hexString == expected)
    }
}
