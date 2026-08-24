// Data 与十六进制字符串互转。用于凭证持久化与日志。

import Foundation

extension Data {
    /// 小写十六进制字符串。
    public var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// 从十六进制字符串解析(忽略空白与大小写)。奇数长度或非法字符返回 nil。
    public init?(hex: String) {
        let cleaned = hex.filter { !$0.isWhitespace }
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes = Data()
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = bytes
    }
}
