// HKDF-SHA512, based on CryptoKit.
// Corresponds to pyatv's hkdf_expand (which is the full HKDF from cryptography: Extract + Expand).

import Foundation
import CryptoKit

public enum HKDF {
    /// Derives a key. Corresponds to pyatv's HKDF(SHA512, length, salt, info).derive(ikm).
    /// Note: pyatv uses empty bytes (b"") as salt to mean "no salt"; pass empty Data here,
    /// not nil (nil is treated by CryptoKit as 64 bytes of zero padding).
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
