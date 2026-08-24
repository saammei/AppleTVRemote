// 二进制 plist 编解码与 RTI 文本输入 payload 测试。
// 参考字节由 Python plistlib 生成(与 pyatv 一致),用于验证解码正确性;
// 编码侧通过与解码 round-trip 验证结构一致。

import Foundation
import AppleTVControl

func runBinaryPlistTests() {
    runSuite("BinaryPlist 解码 _tiD") {
        // 由 fake_device.rti_encoded_data 生成的 _tiD(sessionUUID=0x00..0x0F, text="hello")。
        let tiData = Data(hex: "62706c6973743030d2010203085424746f7058246f626a65637473d2040506075b73657373696f6e555549445d646f63756d656e74537461746580018002a5090a0b0e1155246e756c6c4f1010000102030405060708090a0b0c0d0e0fd10c0d55646f6353748003d10f105f1012636f6e746578744265666f7265496e70757480045568656c6c6f080d121b202c3a3c3e444a5d6066686b80820000000000000101000000000000001200000000000000000000000000000088")!

        let props = RTITextInput.readArchiveProperties(tiData, paths: [
            ["sessionUUID"],
            ["documentState", "docSt", "contextBeforeInput"],
        ])

        let expectedUUID = Data((0..<16).map { UInt8($0) })
        expectEqual(props.count, 2, "解析路径数")
        expectEqual(props[0] as? Data, expectedUUID, "sessionUUID")
        expectEqual(props[1] as? String, "hello", "当前文本")
    }

    runSuite("RTI 输入 payload round-trip") {
        let uuid = Data((0..<16).map { UInt8($0) })
        let payload = RTITextInput.inputTextPayload(sessionUUID: uuid, text: "你好")

        let props = RTITextInput.readArchiveProperties(payload, paths: [
            ["textOperations", "targetSessionUUID", "NS.uuidbytes"],
            ["textOperations", "keyboardOutput", "insertionText"],
        ])

        expectEqual(props[0] as? Data, uuid, "sessionUUID")
        expectEqual(props[1] as? String, "你好", "插入文本(含非 ASCII)")
    }

    runSuite("RTI 清空 payload round-trip") {
        let uuid = Data((0..<16).map { UInt8($0) })
        let payload = RTITextInput.clearTextPayload(sessionUUID: uuid)

        let props = RTITextInput.readArchiveProperties(payload, paths: [
            ["textOperations", "targetSessionUUID", "NS.uuidbytes"],
            ["textOperations", "textToAssert"],
        ])

        expectEqual(props[0] as? Data, uuid, "sessionUUID")
        expectEqual(props[1] as? String, "", "textToAssert 为空串")
    }
}
