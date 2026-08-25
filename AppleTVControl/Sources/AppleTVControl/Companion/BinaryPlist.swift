// 最小二进制 plist(bplist00)编解码,支持 NSKeyedArchiver 所需的 UID 引用。
// 用于 Companion 文本输入:解析 _tiD 里的 sessionUUID/当前文本,并构建 _tiC 的
// RTITextOperations payload。对应 pyatv 用 plistlib 处理的部分。
//
// 类型子集:null / bool / int / data / ascii & utf-16 string / UID / array / dict。
// 与 plistlib 兼容:
//   - UID 字节数 = 1 + (marker & 0x0F)(0x80=1 字节, 0x83=4 字节, 0x87=8 字节)
//   - 数组/字典元素以 ref_size 字节大端无符号整数作引用
//   - 长度/计数 >= 15 时,后跟一个整数对象(0x10..0x13)

import Foundation

/// NSKeyedArchiver 的 UID 引用。
public struct PlistUID: Hashable {
    public let value: Int
    public init(_ value: Int) { self.value = value }
}

public enum BinaryPlist {
    // MARK: - 编码

    public static func encode(_ root: [String: Any]) -> Data {
        var objects: [Any] = []
        var indexByKey: [String: Int] = [:]

        func contentKey(_ value: Any) -> String {
            if let s = value as? String { return "s\(s.utf8.count):\(s)" }
            if let d = value as? Data { return "d\(d.count):\(d.hex)" }
            if let i = value as? Int { return "i:\(i)" }
            if let i = value as? Int64 { return "i:\(i)" }
            if let b = value as? Bool { return "b:\(b ? 1 : 0)" }
            if value is NSNull { return "null" }
            if let u = value as? PlistUID { return "u:\(u.value)" }
            if let dict = value as? [String: Any] {
                var parts = ["{"]
                for k in dict.keys.sorted() {
                    parts.append(contentKey(k))
                    parts.append(contentKey(dict[k]!))
                }
                parts.append("}")
                return parts.joined(separator: ",")
            }
            if let arr = value as? [Any] {
                return "[" + arr.map { contentKey($0) }.joined(separator: ",") + "]"
            }
            fatalError("BinaryPlist 不支持的打包类型: \(type(of: value))")
        }

        func add(_ value: Any) {
            let k = contentKey(value)
            guard indexByKey[k] == nil else { return }
            indexByKey[k] = objects.count
            objects.append(value)
            if let dict = value as? [String: Any] {
                let keys = dict.keys.sorted()
                for key in keys { add(key) }          // 先所有 key
                for key in keys { add(dict[key]!) }   // 再所有 value
            } else if let arr = value as? [Any] {
                for e in arr { add(e) }
            }
        }
        add(root)

        let numObjects = objects.count
        let refSize = countToSize(numObjects)

        // 8 字节魔数头 "bplist00";之后所有偏移都是相对文件起点的绝对偏移。
        var body = Data("bplist00".utf8)
        var offsets: [Int] = []
        for obj in objects {
            offsets.append(body.count)
            body.append(serialize(obj, refOf: { indexByKey[contentKey($0)]! }, refSize: refSize))
        }

        let offsetTableOffset = body.count
        let offsetSize = countToSize(offsetTableOffset)
        for off in offsets {
            body.append(intBytes(off, count: offsetSize))
        }

        // 32 字节 trailer:5 空 + sortVersion(1) + offsetSize(1) + refSize(1) + 3×uint64。
        var trailer = Data(repeating: 0, count: 5)
        trailer.append(0x00)
        trailer.append(UInt8(offsetSize))
        trailer.append(UInt8(refSize))
        trailer.append(uint64Bytes(UInt64(numObjects)))
        trailer.append(uint64Bytes(0))  // top object = root(refnum 0)
        trailer.append(uint64Bytes(UInt64(offsetTableOffset)))
        body.append(trailer)
        return body
    }

    private static func serialize(_ value: Any, refOf: (Any) -> Int, refSize: Int) -> Data {
        if value is NSNull { return Data([0x00]) }
        if let b = value as? Bool { return Data([b ? 0x09 : 0x08]) }
        if let i = value as? Int { return serializeInt(Int64(i)) }
        if let i = value as? Int64 { return serializeInt(i) }
        if let d = value as? Data {
            return serializeSized(0x40, d.count) + d
        }
        if let s = value as? String {
            if let ascii = s.data(using: .ascii) {
                return serializeSized(0x50, ascii.count) + ascii
            } else {
                let utf16 = s.data(using: .utf16BigEndian)!
                return serializeSized(0x60, utf16.count / 2) + utf16
            }
        }
        if let u = value as? PlistUID {
            // 只写 1 字节 UID(0x80),payload 里的 UID 均 < 256。
            return Data([0x80, UInt8(u.value)])
        }
        if let arr = value as? [Any] {
            var d = serializeSized(0xA0, arr.count)
            for e in arr { d.append(intBytes(refOf(e), count: refSize)) }
            return d
        }
        if let dict = value as? [String: Any] {
            let keys = dict.keys.sorted()
            var d = serializeSized(0xD0, keys.count)
            for k in keys { d.append(intBytes(refOf(k), count: refSize)) }
            for k in keys { d.append(intBytes(refOf(dict[k]!), count: refSize)) }
            return d
        }
        fatalError("BinaryPlist 不支持的打包类型: \(type(of: value))")
    }

    private static func serializeInt(_ value: Int64) -> Data {
        precondition(value >= 0, "BinaryPlist 不支持负整数")
        if value < 0x100 { return Data([0x10, UInt8(value)]) }
        if value < 0x1_0000 { return Data([0x11]) + intBytes(Int(value), count: 2) }
        if value < 0x1_0000_0000 { return Data([0x12]) + intBytes(Int(value), count: 4) }
        return Data([0x13]) + intBytes(Int(value), count: 8)
    }

    /// 标记 + 长度;长度 >= 15 时用 0xF + 整数对象。
    private static func serializeSized(_ token: UInt8, _ count: Int) -> Data {
        if count < 15 { return Data([token | UInt8(count)]) }
        return Data([token | 0x0F]) + serializeInt(Int64(count))
    }

    private static func countToSize(_ n: Int) -> Int {
        if n < 0x100 { return 1 }
        if n < 0x1_0000 { return 2 }
        if n < 0x1_0000_0000 { return 4 }
        return 8
    }

    private static func intBytes(_ value: Int, count: Int) -> Data {
        var d = Data(capacity: count)
        for i in stride(from: count - 1, through: 0, by: -1) {
            d.append(UInt8((value >> (8 * i)) & 0xFF))
        }
        return d
    }

    private static func uint64Bytes(_ value: UInt64) -> Data {
        var d = Data(capacity: 8)
        for i in stride(from: 7, through: 0, by: -1) {
            d.append(UInt8((value >> UInt64(8 * i)) & 0xFF))
        }
        return d
    }

    // MARK: - 解码

    /// 解码 bplist,返回根对象(通常是 [String: Any],UID 引用以 PlistUID 表示)。
    public static func decode(_ data: Data) -> Any? {
        let bytes = [UInt8](data)
        guard bytes.count >= 40, bytes.prefix(8) == [0x62, 0x70, 0x6c, 0x69, 0x73, 0x74, 0x30, 0x30] else {
            return nil
        }
        let trailerStart = bytes.count - 32
        let offsetSize = Int(bytes[trailerStart + 6])
        let refSize = Int(bytes[trailerStart + 7])
        // trailer 的 3 个 uint64 字段可能是畸形输入;先取原始值,越界或超出 Int 范围则放弃。
        guard let numObjectsRaw = readUInt64(bytes, trailerStart + 8),
              let topObjectRaw = readUInt64(bytes, trailerStart + 16),
              let offsetTableOffsetRaw = readUInt64(bytes, trailerStart + 24),
              numObjectsRaw <= UInt64(Int.max),
              topObjectRaw <= UInt64(Int.max),
              offsetTableOffsetRaw <= UInt64(Int.max) else { return nil }
        let numObjects = Int(numObjectsRaw)
        let topObject = Int(topObjectRaw)
        let offsetTableOffset = Int(offsetTableOffsetRaw)

        guard offsetSize > 0, refSize > 0, numObjects > 0,
              offsetTableOffset + numObjects * offsetSize <= trailerStart else { return nil }

        var offsets: [Int] = []
        offsets.reserveCapacity(numObjects)
        for i in 0..<numObjects {
            offsets.append(readInt(bytes, offsetTableOffset + i * offsetSize, offsetSize))
        }

        var cache: [Int: Any] = [:]
        return readObject(ref: topObject, bytes: bytes, offsets: offsets, refSize: refSize, cache: &cache)
    }

    private static func readObject(
        ref: Int, bytes: [UInt8], offsets: [Int], refSize: Int, cache: inout [Int: Any]
    ) -> Any {
        if let cached = cache[ref] { return cached }
        guard ref >= 0, ref < offsets.count else { return NSNull() }

        var pos = offsets[ref]
        guard pos >= 0, pos < bytes.count else { return NSNull() }
        let token = Int(bytes[pos]); pos += 1
        let tokenH = token & 0xF0
        let tokenL = token & 0x0F
        var result: Any

        switch token {
        case 0x00: result = NSNull()
        case 0x08: result = false
        case 0x09: result = true
        case 0x0F: result = Data()
        default:
            switch tokenH {
            case 0x10:
                let size = 1 << tokenL
                result = readInt(bytes, pos, size); pos += size
            case 0x40:
                let (size, p) = readSize(tokenL, bytes, pos)
                guard p >= 0, size >= 0, p + size <= bytes.count else { return NSNull() }
                result = Data(bytes[p..<(p + size)]); pos = p + size
            case 0x50:
                let (size, p) = readSize(tokenL, bytes, pos)
                guard p >= 0, size >= 0, p + size <= bytes.count else { return NSNull() }
                result = String(bytes: bytes[p..<(p + size)], encoding: .ascii) ?? ""; pos = p + size
            case 0x60:
                let (size, p) = readSize(tokenL, bytes, pos)
                // size 是 UTF-16 单元数,字节数为 size*2;先防乘法溢出再校验切片范围。
                let (byteLen, overflow) = size.multipliedReportingOverflow(by: 2)
                guard !overflow, p >= 0, byteLen >= 0, p + byteLen <= bytes.count else { return NSNull() }
                result = String(bytes: bytes[p..<(p + byteLen)], encoding: .utf16BigEndian) ?? ""; pos = p + byteLen
            case 0x80:
                let size = 1 + tokenL
                result = PlistUID(readInt(bytes, pos, size)); pos += size
            case 0xA0:
                let (count, p) = readSize(tokenL, bytes, pos)
                var q = p
                var arr: [Any] = []
                arr.reserveCapacity(count)
                cache[ref] = arr
                for _ in 0..<count {
                    let child = readInt(bytes, q, refSize); q += refSize
                    arr.append(readObject(ref: child, bytes: bytes, offsets: offsets, refSize: refSize, cache: &cache))
                }
                cache[ref] = arr
                return arr
            case 0xD0:
                let (count, p) = readSize(tokenL, bytes, pos)
                var q = p
                var keyRefs: [Int] = []
                var valRefs: [Int] = []
                keyRefs.reserveCapacity(count); valRefs.reserveCapacity(count)
                for _ in 0..<count { keyRefs.append(readInt(bytes, q, refSize)); q += refSize }
                for _ in 0..<count { valRefs.append(readInt(bytes, q, refSize)); q += refSize }
                var dict: [String: Any] = [:]
                cache[ref] = dict
                for i in 0..<count {
                    let k = readObject(ref: keyRefs[i], bytes: bytes, offsets: offsets, refSize: refSize, cache: &cache) as? String ?? ""
                    let v = readObject(ref: valRefs[i], bytes: bytes, offsets: offsets, refSize: refSize, cache: &cache)
                    dict[k] = v
                }
                cache[ref] = dict
                return dict
            default:
                return NSNull()
            }
        }
        cache[ref] = result
        return result
    }

    private static func readSize(_ tokenL: Int, _ bytes: [UInt8], _ pos: Int) -> (Int, Int) {
        guard tokenL == 0xF else { return (tokenL, pos) }
        guard pos >= 0, pos < bytes.count else { return (0, pos) }
        let marker = Int(bytes[pos])
        let size = 1 << (marker & 0x0F)
        return (readInt(bytes, pos + 1, size), pos + 1 + size)
    }

    private static func readInt(_ bytes: [UInt8], _ pos: Int, _ size: Int) -> Int {
        // 合法整数对象最多 8 字节;用 UInt64 累积避免 Int 溢出陷阱,超范围返回 0 交由上层 guard。
        guard pos >= 0, size >= 1, size <= 8, pos + size <= bytes.count else { return 0 }
        var value: UInt64 = 0
        for i in 0..<size {
            value = (value << 8) | UInt64(bytes[pos + i])
        }
        guard value <= UInt64(Int.max) else { return 0 }
        return Int(value)
    }

    private static func readUInt64(_ bytes: [UInt8], _ pos: Int) -> UInt64? {
        guard pos >= 0, pos + 8 <= bytes.count else { return nil }
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(bytes[pos + i])
        }
        return value
    }
}
