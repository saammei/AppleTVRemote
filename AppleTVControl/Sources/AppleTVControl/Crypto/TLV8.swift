// TLV8 encode/decode: the binary format used by HomeKit pairing.
// Corresponds to pyatv's pyatv/auth/hap_tlv8.py.
//
// Each record = <1 byte tag><1 byte length><value>. When value exceeds 255 bytes,
// it is split into multiple records with the same tag, which are merged back into
// one contiguous buffer when decoding.

import Foundation

/// TLV8 tag values (HAP specification).
public enum TLV8Tag: UInt8 {
    case method = 0x00
    case identifier = 0x01
    case salt = 0x02
    case publicKey = 0x03
    case proof = 0x04
    case encryptedData = 0x05
    case seqNo = 0x06
    case error = 0x07
    case signature = 0x0A
    case name = 0x11
    case flags = 0x13
}

public enum TLV8 {
    /// Encodes into TLV8 bytes. entries preserve order (same as pyatv's dict insertion order).
    public static func encode(_ entries: [(UInt8, Data)]) -> Data {
        var result = Data()
        for (tag, value) in entries {
            var pos = 0
            while pos < value.count {
                let size = min(value.count - pos, 255)
                result.append(tag)
                result.append(UInt8(size))
                result.append(value.subdata(in: pos..<(pos + size)))
                pos += size
            }
        }
        return result
    }

    /// Decodes TLV8 bytes. Multiple records with the same tag are merged into one value.
    public static func decode(_ data: Data) -> [UInt8: Data] {
        var result: [UInt8: Data] = [:]
        let bytes = [UInt8](data)
        var pos = 0
        while pos + 2 <= bytes.count {
            let tag = bytes[pos]
            let length = Int(bytes[pos + 1])
            pos += 2
            guard pos + length <= bytes.count else { break }
            let value = Data(bytes[pos..<(pos + length)])
            pos += length
            var existing = result[tag] ?? Data()
            existing.append(value)
            result[tag] = existing
        }
        return result
    }
}
