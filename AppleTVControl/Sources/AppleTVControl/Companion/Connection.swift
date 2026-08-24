// Companion 连接层:帧类型、连接层加密、帧编解码。
// 对应 pyatv 的 pyatv/protocols/companion/connection.py。
//
// 帧格式:4 字节头 [FrameType(1) | payload_length(3,大端)] + payload。
// 连接层加密用 Chacha20-Poly1305(12 字节计数器 nonce),AAD 为帧头,16 字节 tag 附加在 payload 后。
// 与认证层(8 字节 nonce)不同,连接层 nonce 为 out/in 两个独立递增的 12 字节小端计数器。

import Foundation
import CryptoKit

public enum FrameType: UInt8 {
    case unknown = 0
    case noOp = 1
    case psStart = 3
    case psNext = 4
    case pvStart = 5
    case pvNext = 6
    case uOpack = 7
    case eOpack = 8
    case pOpack = 9
    case paReq = 10
    case paRsp = 11
    case sessionStartRequest = 16
    case sessionStartResponse = 17
    case sessionData = 18
    case familyIdentityRequest = 32
    case familyIdentityResponse = 33
    case familyIdentityUpdate = 34
}

/// 连接层加密:out/in 两个独立递增的 12 字节小端计数器 nonce。
public final class CompanionCipher {
    private let outKey: Data
    private let inKey: Data
    private var outCounter: UInt64 = 0
    private var inCounter: UInt64 = 0

    public init(outKey: Data, inKey: Data) {
        self.outKey = outKey
        self.inKey = inKey
    }

    public func encrypt(_ data: Data, aad: Data) throws -> Data {
        let nonce = ChaCha20Poly1305.nonceCounter(outCounter)
        outCounter += 1
        return try ChaCha20Poly1305.seal(data, key: outKey, nonce: nonce, aad: aad)
    }

    public func decrypt(_ data: Data, aad: Data) throws -> Data {
        let nonce = ChaCha20Poly1305.nonceCounter(inCounter)
        inCounter += 1
        return try ChaCha20Poly1305.open(data, key: inKey, nonce: nonce, aad: aad)
    }
}

public enum CompanionFrame {
    public static let headerLength = 4
    public static let authTagLength = 16

    /// 编码一帧。cipher 非空且 payload 非空时加密(payload 后附加 16 字节 tag)。
    public static func encode(frameType: FrameType, payload: Data, cipher: CompanionCipher?) throws -> Data {
        var payloadLength = payload.count
        if cipher != nil && payloadLength > 0 {
            payloadLength += authTagLength
        }
        var header = Data([frameType.rawValue])
        header.append(UInt8((payloadLength >> 16) & 0xFF))
        header.append(UInt8((payloadLength >> 8) & 0xFF))
        header.append(UInt8(payloadLength & 0xFF))

        var body = payload
        if let cipher, !payload.isEmpty {
            body = try cipher.encrypt(payload, aad: header)
        }
        return header + body
    }

    /// 从字节流中提取一帧(不解密,解密由调用方用 cipher 处理)。
    /// 返回 (frameType, payload(可能仍加密), consumed 字节数);缓冲不足返回 nil。
    public static func decode(from buffer: Data) -> (frameType: FrameType, payload: Data, consumed: Int)? {
        guard buffer.count >= headerLength else { return nil }
        let type = buffer[buffer.startIndex]
        let length = Int(buffer[buffer.startIndex + 1]) << 16
            | Int(buffer[buffer.startIndex + 2]) << 8
            | Int(buffer[buffer.startIndex + 3])
        let total = headerLength + length
        guard buffer.count >= total else { return nil }
        let payload = buffer.subdata(in: headerLength..<total)
        return (FrameType(rawValue: type) ?? .unknown, payload, total)
    }
}
