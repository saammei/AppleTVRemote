// Companion 文本输入:RTI(Remote Text Input)的 NSKeyedArchiver payload 构建与解析。
// 对应 pyatv 的 protocols/companion/plist_payloads/rti_text_operations.py 与
// keyed_archiver.py。设备端(Apple TV)返回 _tiStart 的 _tiD 为 keyed archive,
// 其中 sessionUUID 直接以字节存在 $objects[1],当前文本在 documentState.docSt.contextBeforeInput。
//
// 发送文本时用 _tiC 事件,payload 为固定结构的 RTITextOperations keyed archive。

import Foundation

public enum RTITextInput {
    /// 按 pyatv 的 read_archive_properties 逐路径解析 keyed archive,
    /// 返回每条路径最终解析到的值(引用失败时为 nil)。
    public static func readArchiveProperties(_ archive: Data, paths: [[String]]) -> [Any?] {
        guard let root = BinaryPlist.decode(archive) as? [String: Any],
              let objects = root["$objects"] as? [Any],
              let top = root["$top"] as? [String: Any] else {
            return paths.map { _ in nil }
        }

        return paths.map { path in
            var element: Any = top
            for key in path {
                guard let dict = element as? [String: Any],
                      let next = dict[key] else { return nil }
                if let uid = next as? PlistUID {
                    guard uid.value < objects.count else { return nil }
                    element = objects[uid.value]
                } else {
                    element = next
                }
            }
            return element
        }
    }

    /// 构建 RTITextOperations「输入文本」payload(_tiC 的 _tiD)。
    public static func inputTextPayload(sessionUUID: Data, text: String) -> Data {
        let objects: [Any] = [
            "$null",
            [
                "keyboardOutput": PlistUID(2),
                "$class": PlistUID(7),
                "targetSessionUUID": PlistUID(5),
            ],
            [
                "insertionText": PlistUID(3),
                "$class": PlistUID(4),
            ],
            text,
            [
                "$classname": "TIKeyboardOutput",
                "$classes": ["TIKeyboardOutput", "NSObject"],
            ],
            [
                "NS.uuidbytes": sessionUUID,
                "$class": PlistUID(6),
            ],
            [
                "$classname": "NSUUID",
                "$classes": ["NSUUID", "NSObject"],
            ],
            [
                "$classname": "RTITextOperations",
                "$classes": ["RTITextOperations", "NSObject"],
            ],
        ]
        return BinaryPlist.encode([
            "$version": 100000,
            "$archiver": "RTIKeyedArchiver",
            "$top": ["textOperations": PlistUID(1)],
            "$objects": objects,
        ])
    }

    /// 构建 RTITextOperations「清空文本」payload(_tiC 的 _tiD)。
    public static func clearTextPayload(sessionUUID: Data) -> Data {
        let objects: [Any] = [
            "$null",
            [
                "$class": PlistUID(7),
                "targetSessionUUID": PlistUID(5),
                "keyboardOutput": PlistUID(2),
                "textToAssert": PlistUID(4),
            ],
            [
                "$class": PlistUID(3),
            ],
            [
                "$classname": "TIKeyboardOutput",
                "$classes": ["TIKeyboardOutput", "NSObject"],
            ],
            "",
            [
                "NS.uuidbytes": sessionUUID,
                "$class": PlistUID(6),
            ],
            [
                "$classname": "NSUUID",
                "$classes": ["NSUUID", "NSObject"],
            ],
            [
                "$classname": "RTITextOperations",
                "$classes": ["RTITextOperations", "NSObject"],
            ],
        ]
        return BinaryPlist.encode([
            "$version": 100000,
            "$archiver": "RTIKeyedArchiver",
            "$top": ["textOperations": PlistUID(1)],
            "$objects": objects,
        ])
    }
}
