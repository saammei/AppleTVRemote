// OPACK 二进制序列化格式,对应 pyatv 的 pyatv/support/opack.py。
//
// Companion 协议的配对消息与控制消息都用 OPACK 编码(连接层帧的 payload)。
// 支持类型:null / bool / int / double / string / data / uuid / array / dict,
// 以及 pack 时的对象引用去重(重复字节串压缩为引用)。
//
// 简化:unpack 的整数统一为 Int64,不保留原始编码字节数(不用于 re-pack)。

import Foundation

public enum OPACK {
    // MARK: - 整数 / 浮点小端辅助

    private static func uintLE(_ value: UInt64, _ count: Int) -> Data {
        var data = Data(capacity: count)
        for i in 0..<count {
            data.append(UInt8((value >> UInt64(8 * i)) & 0xFF))
        }
        return data
    }

    private static func doubleLE(_ value: Double) -> Data {
        var bits = value.bitPattern
        return uintLE(bits, 8)
    }

    private static func intFromLE(_ data: Data) -> Int64 {
        var value: Int64 = 0
        for (i, byte) in data.enumerated() {
            value |= Int64(byte) << (8 * i)
        }
        return value
    }

    // MARK: - pack

    public static func pack(_ value: Any) -> Data {
        var objectList: [Data] = []
        return pack(value, objectList: &objectList)
    }

    private static func pack(_ value: Any, objectList: inout [Data]) -> Data {
        let packed: Data
        if value is NSNull {
            packed = Data([0x04])
        } else if let b = value as? Bool {
            packed = Data([b ? 0x01 : 0x02])
        } else if let u = value as? UUID {
            packed = Data([0x05]) + uuidData(u)
        } else if let i = value as? Int {
            packed = packInt(Int64(i))
        } else if let i = value as? Int64 {
            packed = packInt(i)
        } else if let i = value as? UInt64 {
            packed = packInt(Int64(bitPattern: i))
        } else if let d = value as? Double {
            packed = Data([0x36]) + doubleLE(d)
        } else if let s = value as? String {
            packed = packString(s)
        } else if let data = value as? Data {
            packed = packData(data)
        } else if let arr = value as? [Any] {
            packed = packArray(arr, objectList: &objectList)
        } else if let dict = value as? [String: Any] {
            packed = packDict(dict, objectList: &objectList)
        } else {
            fatalError("OPACK 不支持的打包类型: \(type(of: value))")
        }

        // 对象引用去重:重复的字节串压缩为引用。
        if let idx = objectList.firstIndex(of: packed) {
            if idx < 0x21 {
                return Data([UInt8(0xA0 + idx)])
            } else if idx <= 0xFF {
                return Data([0xC1]) + uintLE(UInt64(idx), 1)
            } else if idx <= 0xFFFF {
                return Data([0xC2]) + uintLE(UInt64(idx), 2)
            } else if idx <= 0xFFFF_FFFF {
                return Data([0xC3]) + uintLE(UInt64(idx), 4)
            } else {
                return Data([0xC4]) + uintLE(UInt64(idx), 8)
            }
        } else if packed.count > 1 {
            objectList.append(packed)
        }
        return packed
    }

    private static func packInt(_ value: Int64) -> Data {
        precondition(value >= 0, "OPACK 不支持负整数")
        if value < 0x28 {
            return Data([UInt8(value + 8)])
        } else if value <= 0xFF {
            return Data([0x30]) + uintLE(UInt64(value), 1)
        } else if value <= 0xFFFF {
            return Data([0x31]) + uintLE(UInt64(value), 2)
        } else if value <= 0xFFFF_FFFF {
            return Data([0x32]) + uintLE(UInt64(value), 4)
        } else {
            return Data([0x33]) + uintLE(UInt64(value), 8)
        }
    }

    private static func packString(_ s: String) -> Data {
        let encoded = Data(s.utf8)
        let len = encoded.count
        if len <= 0x20 {
            return Data([UInt8(0x40 + len)]) + encoded
        } else if len <= 0xFF {
            return Data([0x61]) + uintLE(UInt64(len), 1) + encoded
        } else if len <= 0xFFFF {
            return Data([0x62]) + uintLE(UInt64(len), 2) + encoded
        } else if len <= 0xFFFFFF {
            return Data([0x63]) + uintLE(UInt64(len), 3) + encoded
        } else {
            return Data([0x64]) + uintLE(UInt64(len), 4) + encoded
        }
    }

    private static func packData(_ data: Data) -> Data {
        let len = data.count
        if len <= 0x20 {
            return Data([UInt8(0x70 + len)]) + data
        } else if len <= 0xFF {
            return Data([0x91]) + uintLE(UInt64(len), 1) + data
        } else if len <= 0xFFFF {
            return Data([0x92]) + uintLE(UInt64(len), 2) + data
        } else if len <= 0xFFFF_FFFF {
            return Data([0x93]) + uintLE(UInt64(len), 4) + data
        } else {
            return Data([0x94]) + uintLE(UInt64(len), 8) + data
        }
    }

    private static func packArray(_ arr: [Any], objectList: inout [Data]) -> Data {
        let count = arr.count
        var packed = Data([UInt8(0xD0 + min(count, 0xF))])
        for element in arr {
            packed.append(pack(element, objectList: &objectList))
        }
        if count >= 0xF {
            packed.append(0x03)
        }
        return packed
    }

    private static func packDict(_ dict: [String: Any], objectList: inout [Data]) -> Data {
        let count = dict.count
        var packed = Data([UInt8(0xE0 + min(count, 0xF))])
        for (key, value) in dict {
            packed.append(pack(key, objectList: &objectList))
            packed.append(pack(value, objectList: &objectList))
        }
        if count >= 0xF {
            packed.append(0x03)
        }
        return packed
    }

    // MARK: - unpack

    public static func unpack(_ data: Data) -> (value: Any, remaining: Data)? {
        var objectList: [Any] = []
        return unpack(data, objectList: &objectList)
    }

    private static func unpack(_ data: Data, objectList: inout [Any]) -> (value: Any, remaining: Data)? {
        // dropFirst 返回的是切片视图,底层索引继承原 Data(非从 0 起),
        // 后续 subdata 会因此错位/越界。此处若为切片则强制复制重置索引。
        let data = data.startIndex == 0 ? data : Data(data)
        guard let first = data.first else { return nil }
        var value: Any
        var remaining: Data
        var addToObjectList = true

        switch first {
        case 0x01:
            value = true; remaining = data.dropFirst(); addToObjectList = false
        case 0x02:
            value = false; remaining = data.dropFirst(); addToObjectList = false
        case 0x04:
            value = NSNull(); remaining = data.dropFirst(); addToObjectList = false
        case 0x05:
            guard data.count >= 17 else { return nil }
            let uuidData = data.subdata(in: 1..<17)
            value = uuidFromData(uuidData) ?? UUID()
            remaining = data.dropFirst(17)
        case 0x06:
            guard data.count >= 9 else { return nil }
            value = intFromLE(data.subdata(in: 1..<9))
            remaining = data.dropFirst(9)
        case 0x08...0x2F:
            value = Int64(first - 8)
            remaining = data.dropFirst()
            addToObjectList = false
        case 0x35:
            guard data.count >= 5 else { return nil }
            let bits = UInt32(truncatingIfNeeded: intFromLE(data.subdata(in: 1..<5)))
            value = Double(Float(bitPattern: bits))
            remaining = data.dropFirst(5)
        case 0x36:
            guard data.count >= 9 else { return nil }
            value = Double(bitPattern: UInt64(bitPattern: intFromLE(data.subdata(in: 1..<9))))
            remaining = data.dropFirst(9)
        case 0x30...0x33:
            let byteCount = 1 << (first & 0xF)
            guard data.count >= 1 + byteCount else { return nil }
            value = intFromLE(data.subdata(in: 1..<(1 + byteCount)))
            remaining = data.dropFirst(1 + byteCount)
        case 0x40...0x60:
            let length = Int(first - 0x40)
            guard data.count >= 1 + length else { return nil }
            value = String(data: data.subdata(in: 1..<(1 + length)), encoding: .utf8) ?? ""
            remaining = data.dropFirst(1 + length)
        case 0x61...0x64:
            let byteCount = Int(first & 0xF)
            guard data.count >= 1 + byteCount else { return nil }
            let length = Int(intFromLE(data.subdata(in: 1..<(1 + byteCount))))
            let end = 1 + byteCount + length
            guard data.count >= end else { return nil }
            value = String(data: data.subdata(in: (1 + byteCount)..<end), encoding: .utf8) ?? ""
            remaining = data.dropFirst(end)
        case 0x70...0x90:
            let length = Int(first - 0x70)
            guard data.count >= 1 + length else { return nil }
            value = data.subdata(in: 1..<(1 + length))
            remaining = data.dropFirst(1 + length)
        case 0x91...0x94:
            let byteCount = 1 << (Int(first & 0xF) - 1)
            guard data.count >= 1 + byteCount else { return nil }
            let length = Int(intFromLE(data.subdata(in: 1..<(1 + byteCount))))
            let end = 1 + byteCount + length
            guard data.count >= end else { return nil }
            value = data.subdata(in: (1 + byteCount)..<end)
            remaining = data.dropFirst(end)
        case 0xD0...0xDF:
            let count = Int(first & 0xF)
            var output: [Any] = []
            var ptr = data.dropFirst()
            if count == 0xF {
                while let p = ptr.first, p != 0x03 {
                    guard let (v, rest) = unpack(ptr, objectList: &objectList) else { return nil }
                    output.append(v); ptr = rest
                }
                ptr = ptr.dropFirst()
            } else {
                for _ in 0..<count {
                    guard let (v, rest) = unpack(ptr, objectList: &objectList) else { return nil }
                    output.append(v); ptr = rest
                }
            }
            value = output; remaining = ptr; addToObjectList = false
        case 0xE0...0xEF:
            let count = Int(first & 0xF)
            var output: [String: Any] = [:]
            var ptr = data.dropFirst()
            if count == 0xF {
                while let p = ptr.first, p != 0x03 {
                    guard let (k, rest1) = unpack(ptr, objectList: &objectList),
                          let (v, rest2) = unpack(rest1, objectList: &objectList) else { return nil }
                    if let key = k as? String { output[key] = v }
                    ptr = rest2
                }
                ptr = ptr.dropFirst()
            } else {
                for _ in 0..<count {
                    guard let (k, rest1) = unpack(ptr, objectList: &objectList),
                          let (v, rest2) = unpack(rest1, objectList: &objectList) else { return nil }
                    if let key = k as? String { output[key] = v }
                    ptr = rest2
                }
            }
            value = output; remaining = ptr; addToObjectList = false
        case 0xA0...0xC0:
            let index = Int(first - 0xA0)
            guard index < objectList.count else { return nil }
            value = objectList[index]
            remaining = data.dropFirst()
        case 0xC1...0xC4:
            let byteCount = Int(first - 0xC0)
            guard data.count >= 1 + byteCount else { return nil }
            let index = Int(intFromLE(data.subdata(in: 1..<(1 + byteCount))))
            guard index < objectList.count else { return nil }
            value = objectList[index]
            remaining = data.dropFirst(1 + byteCount)
        default:
            return nil
        }

        if addToObjectList {
            if !contains(objectList, value) {
                objectList.append(value)
            }
        }
        return (value, remaining)
    }

    private static func contains(_ list: [Any], _ value: Any) -> Bool {
        // Data / String 需要按值比较,其余用 isEqual。
        if let valueData = value as? Data {
            return list.contains { ($0 as? Data) == valueData }
        }
        if let valueString = value as? String {
            return list.contains { ($0 as? String) == valueString }
        }
        return list.contains { ($0 as AnyObject) === (value as AnyObject) || isEqual($0, value) }
    }

    private static func isEqual(_ a: Any, _ b: Any) -> Bool {
        if let a = a as? Int64, let b = b as? Int64 { return a == b }
        if let a = a as? Bool, let b = b as? Bool { return a == b }
        return false
    }

    private static func uuidData(_ uuid: UUID) -> Data {
        let ns = uuid as NSUUID
        var bytes = [UInt8](repeating: 0, count: 16)
        ns.getBytes(&bytes)
        return Data(bytes)
    }

    private static func uuidFromData(_ data: Data) -> UUID? {
        guard data.count == 16 else { return nil }
        let bytes = [UInt8](data)
        return bytes.withUnsafeBufferPointer { buf in
            NSUUID(uuidBytes: buf.baseAddress!) as UUID
        }
    }
}
