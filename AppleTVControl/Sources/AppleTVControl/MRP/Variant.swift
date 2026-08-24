// LEB128 变长整数编解码,用于 MRP 消息的长度前缀。
// 对应 pyatv 的 pyatv/support/variant.py(标准 protobuf varint 编码,小端 7 位一组)。
//
// write_variant:每字节低 7 位为数据,最高位为续位;递归 number >> 7。
// read_variant:result |= (byte & 0x7F) << (7 * cnt),遇最高位为 0 的字节结束。

import Foundation

public enum Variant {
    /// 编码为非负变长整数。
    public static func encode(_ value: Int) -> Data {
        precondition(value >= 0, "Variant 不支持负数")
        var number = value
        var result = Data()
        while number >= 0x80 {
            result.append(UInt8((number & 0x7F) | 0x80))
            number >>= 7
        }
        result.append(UInt8(number))
        return result
    }

    /// 从 data 读出一个变长整数,返回 (值, 剩余字节);数据不足/溢出返回 nil。
    public static func decode(_ data: Data) -> (value: Int, remaining: Data)? {
        let bytes = [UInt8](data)
        var result = 0
        var cnt = 0
        for (i, byte) in bytes.enumerated() {
            // 最多 10 字节(64 位 varint 上限),超出视为非法。
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
