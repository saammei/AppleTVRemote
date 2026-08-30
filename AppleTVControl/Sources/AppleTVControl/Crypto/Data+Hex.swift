// Conversion between Data and hex strings. Used for credential persistence and logging.

import Foundation

extension Data {
    /// Lowercase hex string.
    public var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Parses from a hex string (ignores whitespace and case). Returns nil for odd length or invalid characters.
    public init?(hex: String) {
        let cleaned = hex.filter { !$0.isWhitespace }
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes = Data()
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = bytes
    }
}
