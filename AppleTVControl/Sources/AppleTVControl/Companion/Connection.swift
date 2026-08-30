// Companion connection layer: frame types, connection-layer encryption, frame encode/decode.
// Corresponds to pyatv's pyatv/protocols/companion/connection.py.
//
// Frame format: 4-byte header [FrameType(1) | payload_length(3, big-endian)] + payload.
// Connection-layer encryption uses ChaCha20-Poly1305 (12-byte counter nonce); the AAD is the frame
// header, and the 16-byte tag is appended after the payload.
// Unlike the authentication layer (8-byte nonce), the connection layer nonce uses two independently
// incrementing 12-byte little-endian counters (out/in).

import Foundation
import CryptoKit
import os

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

/// Connection-layer encryption: out/in use two independently incrementing 12-byte little-endian counter nonces.
/// Counter reads/writes are protected by os_unfair_lock so send/receive can be called safely across threads.
public final class CompanionCipher {
    private let outKey: Data
    private let inKey: Data
    private var outCounter: UInt64 = 0
    private var inCounter: UInt64 = 0
    private var outLock = os_unfair_lock()
    private var inLock = os_unfair_lock()

    public init(outKey: Data, inKey: Data) {
        self.outKey = outKey
        self.inKey = inKey
    }

    public func encrypt(_ data: Data, aad: Data) throws -> Data {
        os_unfair_lock_lock(&outLock)
        let nonce = ChaCha20Poly1305.nonceCounter(outCounter)
        outCounter += 1
        os_unfair_lock_unlock(&outLock)
        return try ChaCha20Poly1305.seal(data, key: outKey, nonce: nonce, aad: aad)
    }

    public func decrypt(_ data: Data, aad: Data) throws -> Data {
        os_unfair_lock_lock(&inLock)
        let nonce = ChaCha20Poly1305.nonceCounter(inCounter)
        inCounter += 1
        os_unfair_lock_unlock(&inLock)
        return try ChaCha20Poly1305.open(data, key: inKey, nonce: nonce, aad: aad)
    }
}

public enum CompanionFrame {
    public static let headerLength = 4
    public static let authTagLength = 16

    /// Encodes a frame. Encrypts when cipher is non-nil and the payload is non-empty (16-byte tag appended after the payload).
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

    /// Extracts one frame from the byte stream (does not decrypt; decryption is handled by the caller with a cipher).
    /// Returns (frameType, payload (possibly still encrypted), consumed bytes); returns nil if the buffer is insufficient.
    public static func decode(from buffer: Data) -> (frameType: FrameType, payload: Data, consumed: Int)? {
        guard buffer.count >= headerLength else { return nil }
        let header = buffer.prefix(headerLength)
        let type = header[header.startIndex]
        let length = Int(header[header.startIndex + 1]) << 16
            | Int(header[header.startIndex + 2]) << 8
            | Int(header[header.startIndex + 3])
        let total = headerLength + length
        guard buffer.count >= total else { return nil }
        // Use dropFirst/prefix instead of subdata(in:): slice operations clamp to the bounds themselves and cannot trap.
        let payload = Data(buffer.dropFirst(headerLength).prefix(length))
        return (FrameType(rawValue: type) ?? .unknown, payload, total)
    }
}
