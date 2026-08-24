import Foundation
import AppleTVControl

/// OPACK 序列化测试。标量类型(int/str/bytes/bool/null/uuid)逐字节对照 pyatv,
/// dict/list 因 Swift 字典无序,改用 round-trip 与跨语言解码验证。

func runOPACKTests() {
    runSuite("OPACK 标量编码") {
        // 逐字节对照 pyatv 的 opack.pack 输出。
        expectHexEqual([UInt8](OPACK.pack(5)), [UInt8](Data(hex: "0d")!), "int 5")
        expectHexEqual([UInt8](OPACK.pack(39)), [UInt8](Data(hex: "2f")!), "int 39")
        expectHexEqual([UInt8](OPACK.pack(40)), [UInt8](Data(hex: "3028")!), "int 40")
        expectHexEqual([UInt8](OPACK.pack(255)), [UInt8](Data(hex: "30ff")!), "int 255")
        expectHexEqual([UInt8](OPACK.pack(256)), [UInt8](Data(hex: "310001")!), "int 256")
        expectHexEqual([UInt8](OPACK.pack(65535)), [UInt8](Data(hex: "31ffff")!), "int 65535")
        expectHexEqual([UInt8](OPACK.pack(65536)), [UInt8](Data(hex: "3200000100")!), "int 65536")
        expectHexEqual([UInt8](OPACK.pack(Int(1) << 32)), [UInt8](Data(hex: "330000000001000000")!), "int 2^32")

        expectHexEqual([UInt8](OPACK.pack(true)), [UInt8](Data(hex: "01")!), "bool true")
        expectHexEqual([UInt8](OPACK.pack(false)), [UInt8](Data(hex: "02")!), "bool false")
        expectHexEqual([UInt8](OPACK.pack(NSNull())), [UInt8](Data(hex: "04")!), "null")

        expectHexEqual([UInt8](OPACK.pack("")), [UInt8](Data(hex: "40")!), "str empty")
        expectHexEqual([UInt8](OPACK.pack("hello")), [UInt8](Data(hex: "4568656c6c6f")!), "str hello")
        expectHexEqual(
            [UInt8](OPACK.pack(String(repeating: "a", count: 33))),
            [UInt8](Data(hex: "6121" + String(repeating: "61", count: 33))!),
            "str 33")

        expectHexEqual([UInt8](OPACK.pack(Data())), [UInt8](Data(hex: "70")!), "bytes empty")
        expectHexEqual([UInt8](OPACK.pack(Data([0x01, 0x02, 0x03]))), [UInt8](Data(hex: "73010203")!), "bytes 3")
        expectHexEqual(
            [UInt8](OPACK.pack(Data(repeating: 0x04, count: 33))),
            [UInt8](Data(hex: "9121" + String(repeating: "04", count: 33))!),
            "bytes 33")

        let uuid = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
        expectHexEqual([UInt8](OPACK.pack(uuid)), [UInt8](Data(hex: "0512345678123412341234123456789abc")!), "uuid")
    }

    runSuite("OPACK 容器与去重") {
        // 空容器
        expectHexEqual([UInt8](OPACK.pack([Any]())), [UInt8](Data(hex: "d0")!), "empty list")
        expectHexEqual([UInt8](OPACK.pack([String: Any]())), [UInt8](Data(hex: "e0")!), "empty dict")

        // 对象引用去重:重复 bytes 第二次用引用(index 1)。
        // pyatv: pack({"x": b"abc", "y": b"abc"}) = e2 4178 73616263 4179 a1
        let dedup = OPACK.pack(["x": Data("abc".utf8), "y": Data("abc".utf8)] as [String: Any])
        // dict 顺序不定(Swift 字典无序),只验证去重:重复 bytes 第二次用引用字节 a1,
        // 总长度 10(1 字节 dict 头 + 2+4+2 字节 key/value + 1 字节引用)。
        let dedupHex = [UInt8](dedup)
        expectEqual(dedup.count, 10, "dedup 长度")
        expectEqual(dedupHex.last, 0xa1, "dedup 引用字节")

        // 嵌套 dict round-trip
        let msg: [String: Any] = ["_pd": Data([0x01, 0x02]), "_pwTy": 1]
        let packed = OPACK.pack(msg)
        guard let (value, rest) = OPACK.unpack(packed) else {
            expect(false, "unpack 失败"); return
        }
        expectEqual(rest.count, 0, "unpack 剩余为空")
        guard let dict = value as? [String: Any] else {
            expect(false, "unpack 结果非 dict"); return
        }
        expectEqual(dict["_pd"] as? Data, Data([0x01, 0x02]), "_pd 字段")
        expectEqual(dict["_pwTy"] as? Int64, 1, "_pwTy 字段")
    }

    runSuite("OPACK 跨语言解码") {
        // 用 pyatv 生成的字节,验证 Swift unpack 正确解析(含嵌套与引用)。
        // pyatv: pack({"x": b"abc", "y": b"abc"}) = e2 4178 73616263 4179 a1
        let dedupBytes = Data(hex: "e24178736162634179a1")!
        guard let (value, _) = OPACK.unpack(dedupBytes),
              let dict = value as? [String: Any] else {
            expect(false, "dedup unpack 失败"); return
        }
        expectEqual(dict["x"] as? Data, Data("abc".utf8), "dedup x")
        expectEqual(dict["y"] as? Data, Data("abc".utf8), "dedup y")

        // pyatv: pack({"a": 1, "b": "x"}) = e2 4161 09 4162 4178
        let dictBytes = Data(hex: "e241610941624178")!
        guard let (v2, _) = OPACK.unpack(dictBytes),
              let d2 = v2 as? [String: Any] else {
            expect(false, "dict unpack 失败"); return
        }
        expectEqual(d2["a"] as? Int64, 1, "dict a")
        expectEqual(d2["b"] as? String, "x", "dict b")

        // list [1, 2, 3] = d3 09 0a 0b
        let listBytes = Data(hex: "d3090a0b")!
        guard let (v3, _) = OPACK.unpack(listBytes),
              let arr = v3 as? [Any] else {
            expect(false, "list unpack 失败"); return
        }
        expectEqual(arr.count, 3, "list 长度")
        expectEqual(arr[0] as? Int64, 1, "list[0]")
        expectEqual(arr[2] as? Int64, 3, "list[2]")
    }
}
