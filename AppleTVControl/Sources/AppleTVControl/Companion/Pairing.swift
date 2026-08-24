// Companion 配对流程:Pair-Setup(首次配对)与 Pair-Verify(凭证恢复)。
// 对应 pyatv 的 pyatv/protocols/companion/auth.py。
//
// 二者都在 SRPAuthHandler 之上编排消息流,消息结构为 OPACK:
//   Pair-Setup: {"_pd": <TLV 字节>, "_pwTy": 1}
//   Pair-Verify: {"_pd": <TLV 字节>, "_auTy": 4}

import Foundation

enum PairingKeys {
    static let pairingData = "_pd"
    static let pairingType = "_pwTy"
    static let authType = "_auTy"
}

/// 从配对消息中取出 _pd 字节并解码 TLV8;设备报错则抛出。
func pairingTLV(from message: [String: Any]) throws -> [UInt8: Data] {
    guard let pd = message[PairingKeys.pairingData] as? Data else {
        throw CompanionError.protocolError("配对消息缺少 _pd 字段")
    }
    let tlv = TLV8.decode(pd)
    if let err = tlv[TLV8Tag.error.rawValue] {
        let text = String(data: err, encoding: .utf8) ?? "<binary>"
        throw CompanionError.authenticationFailed("设备返回错误: \(text)")
    }
    return tlv
}

/// 首次配对:SRP-6a 交换并交换长期凭证。
public final class CompanionPairSetupProcedure {
    private let protocolLayer: CompanionProtocol
    private let srp: SRPAuthHandler
    private var atvSalt: Data?
    private var atvPubKey: Data?

    public init(_ protocolLayer: CompanionProtocol, _ srp: SRPAuthHandler) {
        self.protocolLayer = protocolLayer
        self.srp = srp
    }

    /// 发起配对(M1/M2):生成密钥,拿到设备的 salt 与公钥。
    /// 可传入固定 seed(各 32 字节)用于确定性测试;nil 则随机生成。
    public func startPairing(
        authPrivateSeed: Data? = nil, verifyPrivateSeed: Data? = nil
    ) async throws {
        try srp.initialize(
            authPrivateSeed: authPrivateSeed, verifyPrivateSeed: verifyPrivateSeed)

        let resp = try await protocolLayer.exchangeAuth(
            .psStart,
            [PairingKeys.pairingData: TLV8.encode([
                (TLV8Tag.method.rawValue, Data([0x00])),
                (TLV8Tag.seqNo.rawValue, Data([0x01])),
            ]),
            PairingKeys.pairingType: 1])

        let tlv = try pairingTLV(from: resp)
        atvSalt = tlv[TLV8Tag.salt.rawValue]
        atvPubKey = tlv[TLV8Tag.publicKey.rawValue]
    }

    /// 完成配对(M3-M6),返回长期凭证。
    public func finishPairing(pin: String, displayName: String? = nil) async throws -> HapCredentials {
        guard let atvPubKey, let atvSalt else {
            throw CompanionError.notConnected
        }

        srp.step1(pin: pin)
        let (pubKey, proof) = try srp.step2(atvPubKey: atvPubKey, atvSalt: atvSalt)

        let resp3 = try await protocolLayer.exchangeAuth(
            .psNext,
            [PairingKeys.pairingData: TLV8.encode([
                (TLV8Tag.seqNo.rawValue, Data([0x03])),
                (TLV8Tag.publicKey.rawValue, pubKey),
                (TLV8Tag.proof.rawValue, proof),
            ]),
            PairingKeys.pairingType: 1])

        _ = try pairingTLV(from: resp3)  // 设备 M4 含 proof,pyatv 未校验(与上游一致)。

        let encryptedData = try srp.step3(name: displayName)
        let resp5 = try await protocolLayer.exchangeAuth(
            .psNext,
            [PairingKeys.pairingData: TLV8.encode([
                (TLV8Tag.seqNo.rawValue, Data([0x05])),
                (TLV8Tag.encryptedData.rawValue, encryptedData),
            ]),
            PairingKeys.pairingType: 1])

        let tlv6 = try pairingTLV(from: resp5)
        guard let deviceEncrypted = tlv6[TLV8Tag.encryptedData.rawValue] else {
            throw CompanionError.invalidResponse
        }
        return try srp.step4(encryptedData: deviceEncrypted)
    }
}

/// 凭证恢复:Curve25519 + Ed25519 验证并派生新加密密钥。
public final class CompanionPairVerifyProcedure {
    private let protocolLayer: CompanionProtocol
    private let srp: SRPAuthHandler
    private let credentials: HapCredentials

    public init(_ protocolLayer: CompanionProtocol, _ srp: SRPAuthHandler, _ credentials: HapCredentials) {
        self.protocolLayer = protocolLayer
        self.srp = srp
        self.credentials = credentials
    }

    /// 用凭证验证设备(M1-M4)。
    @discardableResult
    public func verifyCredentials() async throws -> Bool {
        let (_, publicKey) = try srp.initialize()

        let resp = try await protocolLayer.exchangeAuth(
            .pvStart,
            [PairingKeys.pairingData: TLV8.encode([
                (TLV8Tag.seqNo.rawValue, Data([0x01])),
                (TLV8Tag.publicKey.rawValue, publicKey),
            ]),
            PairingKeys.authType: 4])

        let tlv = try pairingTLV(from: resp)
        guard let serverPubKey = tlv[TLV8Tag.publicKey.rawValue],
              let encrypted = tlv[TLV8Tag.encryptedData.rawValue] else {
            throw CompanionError.invalidResponse
        }

        let encryptedData = try srp.verify1(
            credentials: credentials, sessionPubKey: serverPubKey, encrypted: encrypted)

        _ = try await protocolLayer.exchangeAuth(
            .pvNext,
            [PairingKeys.pairingData: TLV8.encode([
                (TLV8Tag.seqNo.rawValue, Data([0x03])),
                (TLV8Tag.encryptedData.rawValue, encryptedData),
            ])])

        return true
    }

    /// 派生输出/输入加密密钥。
    public func encryptionKeys(
        salt: String, outputInfo: String, inputInfo: String
    ) throws -> (outputKey: Data, inputKey: Data) {
        try srp.verify2(salt: salt, outputInfo: outputInfo, inputInfo: inputInfo)
    }
}
