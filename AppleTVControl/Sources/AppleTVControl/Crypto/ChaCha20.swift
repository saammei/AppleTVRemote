// ChaCha20-Poly1305 加密层,基于 CryptoKit。
// 对应 pyatv 的 pyatv/support/chacha20.py。
//
// pyatv 依赖 cryptography 库的标准 RFC 8439 ChaCha20-Poly1305,nonce 为 12 字节。
// CryptoKit 的 ChaChaPoly 同样是 RFC 8439,12 字节 nonce 直接对应。两种 nonce 构造:
//   - 认证层:前 4 字节为 0 + 8 字节内容(如 "PS-Msg05" / "PV-Msg02")
//   - 连接层:递增计数器(12 字节小端)

import Foundation
import CryptoKit

public enum ChaCha20Poly1305 {
    /// 用 8 字节内容构造 12 字节 nonce(前 4 字节为 0)。用于认证层。
    public static func nonce8(_ content: Data) -> Data {
        var nonce = Data(repeating: 0, count: 4)
        nonce.append(content)
        return nonce
    }

    /// 用 8 字节 ASCII 内容构造 nonce(前 4 字节为 0)。
    public static func nonce8(_ content: String) -> Data {
        nonce8(Data(content.utf8))
    }

    /// 用递增计数器构造 12 字节 nonce(counter 小端)。用于连接层持续加密流。
    public static func nonceCounter(_ counter: UInt64) -> Data {
        var nonce = Data(count: 12)
        var c = counter
        for i in 0..<12 {
            nonce[i] = UInt8(c & 0xFF)
            c >>= 8
        }
        return nonce
    }

    /// MRP 连接层 nonce:前 4 字节为 0 + 8 字节小端计数器(共 12 字节)。
    /// 对应 pyatv 的 Chacha20Cipher8byteNonce(Struct("<LQ").pack(0, counter))。
    public static func nonceCounter8(_ counter: UInt64) -> Data {
        var nonce = Data(repeating: 0, count: 4)
        var c = counter
        for _ in 0..<8 {
            nonce.append(UInt8(c & 0xFF))
            c >>= 8
        }
        return nonce
    }

    /// 加密,返回 ciphertext + 16 字节 tag(与 pyatv 的 encrypt 一致)。
    public static func seal(
        _ message: Data, key: Data, nonce: Data, aad: Data
    ) throws -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let nonceObj = try ChaChaPoly.Nonce(data: nonce)
        let sealed = try ChaChaPoly.seal(
            message, using: symmetricKey, nonce: nonceObj, authenticating: aad)
        // CryptoKit 的 ciphertext/tag 是共享缓冲区的切片,startIndex 可能非 0。
        // 直接用 + 拼接会继承该偏移,导致下游 subdata 越界,故显式拷贝重建。
        var result = Data()
        result.reserveCapacity(sealed.ciphertext.count + sealed.tag.count)
        result.append(sealed.ciphertext)
        result.append(sealed.tag)
        return result
    }

    /// 解密 ciphertext + 16 字节 tag,返回明文。
    public static func open(
        _ combined: Data, key: Data, nonce: Data, aad: Data
    ) throws -> Data {
        guard combined.count >= 16 else {
            throw ChaCha20Error.invalidData
        }
        let ciphertext = combined.prefix(combined.count - 16)
        let tag = combined.suffix(16)
        let symmetricKey = SymmetricKey(data: key)
        let nonceObj = try ChaChaPoly.Nonce(data: nonce)
        let box = try ChaChaPoly.SealedBox(
            nonce: nonceObj, ciphertext: Data(ciphertext), tag: Data(tag))
        return try ChaChaPoly.open(box, using: symmetricKey, authenticating: aad)
    }
}

public enum ChaCha20Error: Error {
    case invalidData
}
