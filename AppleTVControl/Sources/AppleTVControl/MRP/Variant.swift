// LEB128 variable-length integer encode/decode, used for MRP message length prefixes.
// Corresponds to pyatv's pyatv/support/variant.py (standard protobuf varint encoding, little-endian 7 bits per group).
//
// write_variant: low 7 bits of each byte carry data, the high bit is the continuation bit; recurses on number >> 7.
// read_variant: result |= (byte & 0x7F) << (7 * cnt), ends at the first byte whose high bit is 0.

import Foundation

public enum Variant {
    /// Encodes a non-negative variable-length integer.
    public static func encode(_ value: Int) -> Data {
        precondition(value >= 0, "Variant does not support negative numbers")
        var number = value
        var result = Data()
        while number >= 0x80 {
            result.append(UInt8((number & 0x7F) | 0x80))
            number >>= 7
        }
        result.append(UInt8(number))
        return result
    }

    /// Reads one variable-length integer from data, returning (value, remaining bytes); returns nil for insufficient data/overflow.
    public static func decode(_ data: Data) -> (value: Int, remaining: Data)? {
        let bytes = [UInt8](data)
        var result = 0
        var cnt = 0
        for (i, byte) in bytes.enumerated() {
            // At most 10 bytes (the 64-bit varint limit); anything beyond is treated as invalid.
            if cnt >= 10 { return nil }
            result |= Int(byte & 0x7F) << (7 * cnt)
            cnt += 1
            if byte & 0x80 == 0 {
                return (result, data.subdata(in: (i + 1)..<data.count))
            }
        }
        return nil
    }
}
