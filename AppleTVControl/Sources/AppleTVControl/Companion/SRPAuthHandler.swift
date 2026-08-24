// SRP 认证处理器:配对(Pair-Setup)与验证(Pair-Verify)的加密逻辑。
// 对应 pyatv 的 pyatv/auth/hap_srp.py 的 SRPAuthHandler。
//
// Pair-Setup 建立长期凭证(Ed25519 签名密钥 + SRP),Pair-Verify 用已有凭证
// 派生会话密钥(X25519 + HKDF)。两者都复用本文件的密钥生成与加解密。

import Foundation
import CryptoKit

public enum SRPError: Error, Equatable {
    case notInitialized
    case srpRejected
    case invalidResponse
    case authenticationFailed(String)
}

public final class SRPAuthHandler {
    /// 客户端配对标识(UUID 字符串,36 字节)。Pair-Setup 时作为新 client_id。
    public let pairingId: Data

    // Pair-Setup 密钥(Ed25519 签名)
    private var signingKey: Curve25519.Signing.PrivateKey?
    private var authPrivate: Data?
    private var authPublic: Data?

    // Pair-Verify 密钥(X25519)
    private var verifyPrivate: Curve25519.KeyAgreement.PrivateKey?
    private var publicBytes: Data?

    // 中间状态
    private var pin: String?
    private var srpSessionKey: Data?   // SRP K(64 字节)
    private var sharedSecret: Data?    // X25519 shared secret(32 字节)
    private var sessionKey: Data?      // Pair-Setup 加密密钥(32 字节)

    public init(pairingId: Data? = nil) {
        if let pairingId {
            self.pairingId = pairingId
        } else {
            // pyatv 用 str(uuid.uuid4()),小写 36 字节。
            self.pairingId = Data(UUID().uuidString.lowercased().utf8)
        }
    }

    // MARK: - 密钥生成

    /// 生成 Ed25519 签名密钥 + X25519 密钥。返回 (authPublic, publicBytes)。
    /// 传入固定 seed(各 32 字节)用于确定性测试或凭证恢复;nil 则随机生成。
    @discardableResult
    public func initialize(
        authPrivateSeed: Data? = nil,
        verifyPrivateSeed: Data? = nil
    ) throws -> (authPublic: Data, publicBytes: Data) {
        let signing: Curve25519.Signing.PrivateKey
        if let authPrivateSeed {
            signing = try Curve25519.Signing.PrivateKey(rawRepresentation: authPrivateSeed)
        } else {
            signing = Curve25519.Signing.PrivateKey()
        }
        let verifyPriv: Curve25519.KeyAgreement.PrivateKey
        if let verifyPrivateSeed {
            verifyPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: verifyPrivateSeed)
        } else {
            verifyPriv = Curve25519.KeyAgreement.PrivateKey()
        }

        let authPub = signing.publicKey.rawRepresentation
        let verifyPub = verifyPriv.publicKey.rawRepresentation
        signingKey = signing
        authPrivate = signing.rawRepresentation
        authPublic = authPub
        verifyPrivate = verifyPriv
        publicBytes = verifyPub
        return (authPub, verifyPub)
    }

    // MARK: - Pair-Setup(SRP)

    /// step1:记录 PIN(实际 SRP 计算在 step2)。
    public func step1(pin: String) {
        self.pin = pin
    }

    /// step2:计算客户端公钥 A 与证明 M。返回 (A 的最小字节数, M)。
    public func step2(atvPubKey: Data, atvSalt: Data) throws -> (pubKey: Data, proof: Data) {
        guard let authPrivate, let pin else { throw SRPError.notInitialized }
        guard let result = SRP6a.process(
            username: "Pair-Setup", password: pin,
            clientPrivateBytes: authPrivate,
            serverPublicBytes: atvPubKey, salt: atvSalt
        ) else {
            throw SRPError.srpRejected
        }
        srpSessionKey = result.sessionKey
        return (result.clientPublic, result.proof)
    }

    /// step3:构造并加密控制器信息(标识 + 公钥 + 签名)。返回密文(PS-Msg05)。
    public func step3(name: String? = nil) throws -> Data {
        guard let signingKey, let authPublic, let srpSessionKey else {
            throw SRPError.notInitialized
        }

        let iosDeviceX = HKDF.sha512(
            ikm: srpSessionKey,
            salt: Data("Pair-Setup-Controller-Sign-Salt".utf8),
            info: Data("Pair-Setup-Controller-Sign-Info".utf8))
        let sessionKey = HKDF.sha512(
            ikm: srpSessionKey,
            salt: Data("Pair-Setup-Encrypt-Salt".utf8),
            info: Data("Pair-Setup-Encrypt-Info".utf8))
        self.sessionKey = sessionKey

        var deviceInfo = Data()
        deviceInfo.append(iosDeviceX)
        deviceInfo.append(pairingId)
        deviceInfo.append(authPublic)
        let deviceSignature = try signingKey.signature(for: deviceInfo)

        let entries: [(UInt8, Data)] = [
            (TLV8Tag.identifier.rawValue, pairingId),
            (TLV8Tag.publicKey.rawValue, authPublic),
            (TLV8Tag.signature.rawValue, deviceSignature),
        ]
        // Name 字段需要 opack 序列化,留待 Phase 3 与消息层一并实现。
        // pyatv: tlv[Name] = opack.pack({"name": name})

        let tlv = TLV8.encode(entries)
        let nonce = ChaCha20Poly1305.nonce8("PS-Msg05")
        return try ChaCha20Poly1305.seal(tlv, key: sessionKey, nonce: nonce, aad: Data())
    }

    /// step4:解密设备信息(PS-Msg06),得到长期凭证。
    public func step4(encryptedData: Data) throws -> HapCredentials {
        guard let sessionKey, let authPrivate else { throw SRPError.notInitialized }

        let nonce = ChaCha20Poly1305.nonce8("PS-Msg06")
        let decrypted = try ChaCha20Poly1305.open(encryptedData, key: sessionKey, nonce: nonce, aad: Data())
        let tlv = TLV8.decode(decrypted)

        guard let atvIdentifier = tlv[TLV8Tag.identifier.rawValue],
              let atvPubKey = tlv[TLV8Tag.publicKey.rawValue] else {
            throw SRPError.invalidResponse
        }
        // pyatv 在此未验证设备签名(TODO),保持同样行为。

        return HapCredentials(
            ltpk: atvPubKey, ltsk: authPrivate,
            atvId: atvIdentifier, clientId: pairingId)
    }

    // MARK: - Pair-Verify

    /// verify1:用凭证验证设备并签名控制器信息。返回密文(PV-Msg03)。
    public func verify1(
        credentials: HapCredentials, sessionPubKey: Data, encrypted: Data
    ) throws -> Data {
        guard let verifyPrivate, let publicBytes else { throw SRPError.notInitialized }

        let serverPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: sessionPubKey)
        let shared = try verifyPrivate.sharedSecretFromKeyAgreement(with: serverPublic)
        let sharedBytes = shared.withUnsafeBytes { Data($0) }
        sharedSecret = sharedBytes

        let sessionKey = HKDF.sha512(
            ikm: sharedBytes,
            salt: Data("Pair-Verify-Encrypt-Salt".utf8),
            info: Data("Pair-Verify-Encrypt-Info".utf8))

        let nonce2 = ChaCha20Poly1305.nonce8("PV-Msg02")
        let decrypted = try ChaCha20Poly1305.open(encrypted, key: sessionKey, nonce: nonce2, aad: Data())
        let tlv = TLV8.decode(decrypted)

        guard let identifier = tlv[TLV8Tag.identifier.rawValue],
              let signature = tlv[TLV8Tag.signature.rawValue] else {
            throw SRPError.invalidResponse
        }

        guard identifier == credentials.atvId else {
            throw SRPError.authenticationFailed("incorrect device response")
        }

        // 验证设备签名:info = sessionPubKey + identifier + publicBytes
        var info = Data()
        info.append(sessionPubKey)
        info.append(identifier)
        info.append(publicBytes)
        let ltpk = try Curve25519.Signing.PublicKey(rawRepresentation: credentials.ltpk)
        guard ltpk.isValidSignature(signature, for: info) else {
            throw SRPError.authenticationFailed("signature error")
        }

        // 签名控制器信息:device_info = publicBytes + clientId + sessionPubKey
        var deviceInfo = Data()
        deviceInfo.append(publicBytes)
        deviceInfo.append(credentials.clientId)
        deviceInfo.append(sessionPubKey)
        let ltsk = try Curve25519.Signing.PrivateKey(rawRepresentation: credentials.ltsk)
        let deviceSignature = try ltsk.signature(for: deviceInfo)

        let responseTLV = TLV8.encode([
            (TLV8Tag.identifier.rawValue, credentials.clientId),
            (TLV8Tag.signature.rawValue, deviceSignature),
        ])
        let nonce3 = ChaCha20Poly1305.nonce8("PV-Msg03")
        return try ChaCha20Poly1305.seal(responseTLV, key: sessionKey, nonce: nonce3, aad: Data())
    }

    /// verify2:派生输出/输入加密密钥。
    public func verify2(salt: String, outputInfo: String, inputInfo: String) throws -> (outputKey: Data, inputKey: Data) {
        guard let sharedSecret else { throw SRPError.notInitialized }
        let outputKey = HKDF.sha512(
            ikm: sharedSecret, salt: Data(salt.utf8), info: Data(outputInfo.utf8))
        let inputKey = HKDF.sha512(
            ikm: sharedSecret, salt: Data(salt.utf8), info: Data(inputInfo.utf8))
        return (outputKey, inputKey)
    }
}
