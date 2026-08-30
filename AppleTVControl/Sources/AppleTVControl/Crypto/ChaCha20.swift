// ChaCha20-Poly1305 encryption layer, based on CryptoKit.
// Corresponds to pyatv's pyatv/support/chacha20.py.
//
// pyatv relies on the cryptography library's standard RFC 8439 ChaCha20-Poly1305 with a 12-byte nonce.
// CryptoKit's ChaChaPoly is also RFC 8439, so the 12-byte nonce maps directly. Two nonce constructions:
//   - Authentication layer: 4 zero bytes + 8 bytes of content (e.g. "PS-Msg05" / "PV-Msg02")
//   - Connection layer: incrementing counter (12 bytes little-endian)

import Foundation
import CryptoKit

public enum ChaCha20Poly1305 {
    /// Builds a 12-byte nonce from 8 bytes of content (first 4 bytes zero). Used by the authentication layer.
    public static func nonce8(_ content: Data) -> Data {
        var nonce = Data(repeating: 0, count: 4)
        nonce.append(content)
        return nonce
    }

    /// Builds a nonce from 8 bytes of ASCII content (first 4 bytes zero).
    public static func nonce8(_ content: String) -> Data {
        nonce8(Data(content.utf8))
    }

    /// Builds a 12-byte nonce from an incrementing counter (little-endian). Used for the connection layer's continuous encrypted stream.
    public static func nonceCounter(_ counter: UInt64) -> Data {
        var nonce = Data(count: 12)
        var c = counter
        for i in 0..<12 {
            nonce[i] = UInt8(c & 0xFF)
            c >>= 8
        }
        return nonce
    }

    /// MRP connection-layer nonce: 4 zero bytes + 8-byte little-endian counter (12 bytes total).
    /// Corresponds to pyatv's Chacha20Cipher8byteNonce (Struct("<LQ").pack(0, counter)).
    public static func nonceCounter8(_ counter: UInt64) -> Data {
        var nonce = Data(repeating: 0, count: 4)
        var c = counter
        for _ in 0..<8 {
            nonce.append(UInt8(c & 0xFF))
            c >>= 8
        }
        return nonce
    }

    /// Encrypts and returns ciphertext + 16-byte tag (same as pyatv's encrypt).
    public static func seal(
        _ message: Data, key: Data, nonce: Data, aad: Data
    ) throws -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let nonceObj = try ChaChaPoly.Nonce(data: nonce)
        let sealed = try ChaChaPoly.seal(
            message, using: symmetricKey, nonce: nonceObj, authenticating: aad)
        // CryptoKit's ciphertext/tag are slices of a shared buffer, so startIndex may be non-zero.
        // Concatenating directly with + would inherit that offset and cause downstream subdata
        // to go out of bounds, so we explicitly copy and rebuild.
        var result = Data()
        result.reserveCapacity(sealed.ciphertext.count + sealed.tag.count)
        result.append(sealed.ciphertext)
        result.append(sealed.tag)
        return result
    }

    /// Decrypts ciphertext + 16-byte tag and returns plaintext.
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
