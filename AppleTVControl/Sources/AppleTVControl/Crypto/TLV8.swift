// TLV8 编解码:HomeKit 配对使用的二进制格式。
// 对应 pyatv 的 pyatv/auth/hap_tlv8.py。
//
// 每条记录 = <1 字节 tag><1 字节长度><value>。value 超过 255 字节时,
// 拆成多条相同 tag 的记录,解码时再合并回一个连续 buffer。

import Foundation

/// TLV8 标签值(HAP 规范)。
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
    /// 编码为 TLV8 字节。entries 保持顺序(与 pyatv 的 dict 插入顺序一致)。
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

    /// 解码 TLV8 字节。相同 tag 的多条记录合并为一个 value。
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
