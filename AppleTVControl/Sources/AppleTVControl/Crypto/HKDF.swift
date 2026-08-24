// HKDF-SHA512,基于 CryptoKit。
// 对应 pyatv 的 hkdf_expand(实际是 cryptography 的完整 HKDF:Extract + Expand)。

import Foundation
import CryptoKit

public enum HKDF {
    /// 派生密钥。对应 pyatv 的 HKDF(SHA512, length, salt, info).derive(ikm)。
    /// 注意:pyatv 用空 bytes(b"") 作为 salt 表示「无 salt」,这里传空 Data,
    /// 而不是 nil(nil 会被 CryptoKit 当作 64 字节零填充)。
    public static func sha512(
        ikm: Data, salt: Data, info: Data, outputByteCount: Int = 32
    ) -> Data {
        let key = CryptoKit.HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: info,
            outputByteCount: outputByteCount)
        return key.withUnsafeBytes { Data($0) }
    }
}
