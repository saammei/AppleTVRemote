// Companion text input: building and parsing RTI (Remote Text Input) NSKeyedArchiver payloads.
// Corresponds to pyatv's protocols/companion/plist_payloads/rti_text_operations.py and
// keyed_archiver.py. The _tiD returned by the device (Apple TV) for _tiStart is a keyed archive
// where sessionUUID is stored directly as bytes in $objects[1], and the current text lives in
// documentState.docSt.contextBeforeInput.
//
// Text is sent via the _tiC event, whose payload is an RTITextOperations keyed archive with a fixed structure.

import Foundation

public enum RTITextInput {
    /// Resolves a keyed archive along each path, like pyatv's read_archive_properties,
    /// returning the final value resolved for each path (nil if a reference fails).
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

    /// Builds the RTITextOperations "input text" payload (_tiD of _tiC).
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

    /// Builds the RTITextOperations "clear text" payload (_tiD of _tiC).
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
