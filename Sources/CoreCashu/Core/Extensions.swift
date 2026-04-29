import Foundation

// Internal hex/string conveniences used by NUT serialization and tests. These
// intentionally do not extend the public API surface — consumers who need
// hex codecs should rely on CryptoSwift's `Data.bytes` / `Array.toHexString()`
// or write their own utilities.

extension Data {
    init?(hexString: String) {
        let cleanHex = hexString.replacingOccurrences(of: " ", with: "")
        guard cleanHex.count % 2 == 0 else { return nil }

        var data = Data()
        var index = cleanHex.startIndex

        while index < cleanHex.endIndex {
            let nextIndex = cleanHex.index(index, offsetBy: 2)
            let byteString = cleanHex[index..<nextIndex]

            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            data.append(byte)

            index = nextIndex
        }

        self = data
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

extension Array where Element == UInt8 {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

extension String {
    var isValidHex: Bool {
        let hexRegex = "^[0-9a-fA-F]+$"
        return range(of: hexRegex, options: .regularExpression) != nil
    }

    var hexData: Data? {
        Data(hexString: self)
    }

    var isNilOrEmpty: Bool {
        isEmpty
    }
}

extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool {
        self?.isEmpty ?? true
    }
}
