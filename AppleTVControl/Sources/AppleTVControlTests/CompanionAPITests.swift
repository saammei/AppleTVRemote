// CompanionAPI 控制层测试:在加密通道之上验证按键/媒体/电源/应用/订阅命令的
// 消息结构与响应解析,以及 connect() 的完整会话初始化序列(含 Pair-Verify)。
//
// 用内存 mock 连接(不加密)替代 TCP:mock 解析发送帧里的 _x/_i,按脚本回放响应。
// 认证帧(Pair-Verify)由 PairVerifyServer 扮演设备端完成真实加密交换。

import Foundation
import CryptoKit
import AppleTVControl

/// 内存 mock 连接:OPACK 命令按 _i 回放 _c(缺省回空 _c),支持 _em 报错;
/// 认证帧(PV_*)交给 authHandler(PairVerifyServer)。
final class AutoOpackConnection: CompanionConnection {
    var isConnected = false
    weak var listener: CompanionConnectionListener?
    private(set) var sentFrames: [(FrameType, Data)] = []

    /// 命令响应内容: _i -> _c。
    var opackContent: [String: [String: Any]] = [:]
    /// 命令报错: _i -> 错误信息(回 _em)。
    var opackErrors: [String: String] = [:]
    /// 认证帧处理器(connect 测试用,扮演设备端)。
    var authHandler: ((FrameType, Data) -> (FrameType, Data)?)?
    /// 收到的 _interest 事件(fire-and-forget,不回)。
    private(set) var interestEvents: [[String: Any]] = []

    func connect() async throws { isConnected = true }
    func close() { isConnected = false }
    func enableEncryption(outputKey: Data, inputKey: Data) {}

    func send(_ frameType: FrameType, payload: Data) throws {
        sentFrames.append((frameType, payload))

        if isAuthFrame(frameType) {
            if let (rt, rp) = authHandler?(frameType, payload) {
                listener?.connection(self, didReceive: rt, payload: rp)
            }
            return
        }

        guard let (value, _) = OPACK.unpack(payload),
              let dict = value as? [String: Any] else { return }

        let identifier = dict["_i"] as? String
        // _interest 是事件,不等待响应。
        if identifier == "_interest" {
            interestEvents.append(dict)
            return
        }
        guard let xid = dict["_x"] as? Int64, let identifier else { return }

        var response: [String: Any] = ["_x": xid, "_t": Int64(3)]
        if let error = opackErrors[identifier] {
            response["_em"] = error
        } else {
            response["_c"] = opackContent[identifier] ?? [:]
        }
        listener?.connection(self, didReceive: .eOpack, payload: OPACK.pack(response))
    }

    private func isAuthFrame(_ frameType: FrameType) -> Bool {
        switch frameType {
        case .psStart, .psNext, .pvStart, .pvNext: return true
        default: return false
        }
    }

    /// 解包第 index 帧,返回 (_i, _c, _t)。
    func sentCommand(_ index: Int) -> (identifier: String, content: [String: Any], type: Int64)? {
        guard index < sentFrames.count,
              let (value, _) = OPACK.unpack(sentFrames[index].1),
              let dict = value as? [String: Any],
              let id = dict["_i"] as? String else { return nil }
        return (id, dict["_c"] as? [String: Any] ?? [:], dict["_t"] as? Int64 ?? 0)
    }
}

/// 扮演设备的 Pair-Verify 服务端:与客户端(CompanionAPI.connect)完成真实加密交换。
final class PairVerifyServer {
    private let serverSigning: Curve25519.Signing.PrivateKey  // 设备长期签名密钥(ltpk)
    private let credentials: HapCredentials
    private var verifyPrivate: Curve25519.KeyAgreement.PrivateKey?
    private var sessionKey: Data?

    init(serverSigning: Curve25519.Signing.PrivateKey, credentials: HapCredentials) {
        self.serverSigning = serverSigning
        self.credentials = credentials
    }

    func handle(_ frameType: FrameType, _ payload: Data) -> (FrameType, Data)? {
        switch frameType {
        case .pvStart: return handleM1(payload)
        case .pvNext: return handleM3()
        default: return nil
        }
    }

    private func handleM1(_ payload: Data) -> (FrameType, Data)? {
        guard let (value, _) = OPACK.unpack(payload),
              let dict = value as? [String: Any],
              let pd = dict["_pd"] as? Data else { return nil }
        let tlv = TLV8.decode(pd)
        guard let clientPubKey = tlv[TLV8Tag.publicKey.rawValue],
              let clientPublic = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientPubKey) else {
            return nil
        }

        let vp = Curve25519.KeyAgreement.PrivateKey()
        verifyPrivate = vp
        let serverPubKey = vp.publicKey.rawRepresentation
        let shared = try! vp.sharedSecretFromKeyAgreement(with: clientPublic)
        let sharedBytes = shared.withUnsafeBytes { Data($0) }
        let sk = HKDF.sha512(
            ikm: sharedBytes,
            salt: Data("Pair-Verify-Encrypt-Salt".utf8),
            info: Data("Pair-Verify-Encrypt-Info".utf8))
        sessionKey = sk

        var info = Data()
        info.append(serverPubKey)
        info.append(credentials.atvId)
        info.append(clientPubKey)
        let signature = try! serverSigning.signature(for: info)

        let responseTLV = TLV8.encode([
            (TLV8Tag.identifier.rawValue, credentials.atvId),
            (TLV8Tag.signature.rawValue, signature),
        ])
        let encrypted = try! ChaCha20Poly1305.seal(
            responseTLV, key: sk, nonce: ChaCha20Poly1305.nonce8("PV-Msg02"), aad: Data())

        let responsePD = TLV8.encode([
            (TLV8Tag.publicKey.rawValue, serverPubKey),
            (TLV8Tag.encryptedData.rawValue, encrypted),
        ])
        return (.pvNext, OPACK.pack(["_pd": responsePD, "_auTy": 4]))
    }

    private func handleM3() -> (FrameType, Data)? {
        // 客户端 M3 已由客户端 verify1 加密;此处仅回空确认(客户端不校验该响应体)。
        return (.pvNext, OPACK.pack([:]))
    }
}

func dummyCredentials() -> HapCredentials {
    HapCredentials(
        ltpk: Data(repeating: 0xAA, count: 32),
        ltsk: Data(repeating: 0xBB, count: 32),
        atvId: Data("atv-id".utf8),
        clientId: Data("client-id".utf8))
}

func makeAPI(_ mock: AutoOpackConnection) -> CompanionAPI {
    let srp = SRPAuthHandler(pairingId: Data("client-id".utf8))
    let proto = CompanionProtocol(connection: mock, srp: srp)
    let deviceInfo = CompanionDeviceInfo(name: "Test Remote", model: "Mac", identifier: "test-device-id")
    return CompanionAPI(protocolLayer: proto, credentials: dummyCredentials(), deviceInfo: deviceInfo)
}

func runCompanionAPITests() async {
    await runSuiteAsync("按键 press") {
        let mock = AutoOpackConnection()
        let api = makeAPI(mock)

        try await api.press(.up)

        expectEqual(mock.sentFrames.count, 2, "press 发送 2 帧")
        let down = mock.sentCommand(0)
        expectEqual(down?.identifier, "_hidC", "按下帧命令名")
        expectEqual(down?.content["_hBtS"] as? Int64, 1, "按下 _hBtS")
        expectEqual(down?.content["_hidC"] as? Int64, HidCommand.up.rawValue, "按下 _hidC")
        let up = mock.sentCommand(1)
        expectEqual(up?.identifier, "_hidC", "抬起帧命令名")
        expectEqual(up?.content["_hBtS"] as? Int64, 2, "抬起 _hBtS")
        expectEqual(up?.content["_hidC"] as? Int64, HidCommand.up.rawValue, "抬起 _hidC")
    }

    await runSuiteAsync("媒体命令") {
        let mock = AutoOpackConnection()
        let api = makeAPI(mock)

        _ = try await api.mediaCommand(.play)
        expectEqual(mock.sentCommand(0)?.identifier, "_mcc", "播放命令名")
        expectEqual(mock.sentCommand(0)?.content["_mcc"] as? Int64, MediaControlCommand.play.rawValue, "播放 _mcc")
    }

    await runSuiteAsync("音量 / 快进") {
        let mock = AutoOpackConnection()
        let api = makeAPI(mock)

        try await api.setVolume(0.5)
        expectEqual(mock.sentCommand(0)?.content["_mcc"] as? Int64, MediaControlCommand.setVolume.rawValue, "音量 _mcc")
        expectEqual(mock.sentCommand(0)?.content["_vol"] as? Double, 0.5, "音量 _vol")

        try await api.skip(seconds: 10)
        expectEqual(mock.sentCommand(1)?.content["_mcc"] as? Int64, MediaControlCommand.skipBy.rawValue, "快进 _mcc")
        expectEqual(mock.sentCommand(1)?.content["_skpS"] as? Double, 10, "快进 _skpS")
    }

    await runSuiteAsync("电源") {
        let mock = AutoOpackConnection()
        let api = makeAPI(mock)

        try await api.turnOn()
        expectEqual(mock.sentCommand(0)?.content["_hidC"] as? Int64, HidCommand.wake.rawValue, "唤醒按键")
        try await api.turnOff()
        expectEqual(mock.sentCommand(1)?.content["_hidC"] as? Int64, HidCommand.sleep.rawValue, "睡眠按键")
    }

    await runSuiteAsync("应用列表") {
        let mock = AutoOpackConnection()
        let api = makeAPI(mock)
        mock.opackContent["FetchLaunchableApplicationsEvent"] = [
            "com.apple.TVApp": "电视",
            "com.apple.Arcade": "街机",
        ]

        let apps = try await api.appList()

        expectEqual(mock.sentCommand(0)?.identifier, "FetchLaunchableApplicationsEvent", "应用列表命令名")
        expectEqual(apps["com.apple.TVApp"], "电视", "应用 1")
        expectEqual(apps["com.apple.Arcade"], "街机", "应用 2")
    }

    await runSuiteAsync("启动应用") {
        let mock = AutoOpackConnection()
        let api = makeAPI(mock)

        try await api.launchApp("com.apple.TVApp")

        expectEqual(mock.sentCommand(0)?.identifier, "_launchApp", "启动命令名")
        expectEqual(mock.sentCommand(0)?.content["_bundleID"] as? String, "com.apple.TVApp", "启动 bundleID")
    }

    await runSuiteAsync("查询系统状态") {
        let mock = AutoOpackConnection()
        let api = makeAPI(mock)
        mock.opackContent["FetchAttentionState"] = ["state": Int64(SystemStatus.awake.rawValue)]

        let state = try await api.fetchAttentionState()

        expectEqual(mock.sentCommand(0)?.identifier, "FetchAttentionState", "状态命令名")
        expectEqual(state, .awake, "状态值")
    }

    await runSuiteAsync("事件订阅 / 取消") {
        let mock = AutoOpackConnection()
        let api = makeAPI(mock)

        try api.subscribeEvent("_iMC")
        try api.unsubscribeEvent("_iMC")

        expectEqual(mock.interestEvents.count, 2, "订阅事件数")
        let ev0 = mock.interestEvents[0]
        expectEqual(ev0["_t"] as? Int64, CompanionMessageType.event.rawValue, "订阅为事件帧")
        expectEqual((ev0["_c"] as? [String: Any])?["_regEvents"] as? [String], ["_iMC"], "订阅 _regEvents")
        let ev1 = mock.interestEvents[1]
        expectEqual((ev1["_c"] as? [String: Any])?["_deregEvents"] as? [String], ["_iMC"], "取消 _deregEvents")
    }

    await runSuiteAsync("命令报错 _em") {
        let mock = AutoOpackConnection()
        let api = makeAPI(mock)
        mock.opackErrors["_hidC"] = "按键失败"

        var thrown: CompanionError?
        do {
            try await api.press(.select)
        } catch let error as CompanionError {
            thrown = error
        } catch {}

        guard let thrown else {
            expect(false, "未抛出 CompanionError"); return
        }
        if case .protocolError(let text) = thrown {
            expectEqual(text, "按键失败", "报错文本")
        } else {
            expect(false, "错误类型不是 protocolError")
        }
    }

    await runSuiteAsync("文本输入 textSet / textAppend / textClear") {
        // _tiStart 返回的 _tiD(与 pyatv 一致):sessionUUID = 0x00..0x0F,当前文本 "hello"。
        let tiData = Data(hex: "62706c6973743030d2010203085424746f7058246f626a65637473d2040506075b73657373696f6e555549445d646f63756d656e74537461746580018002a5090a0b0e1155246e756c6c4f1010000102030405060708090a0b0c0d0e0fd10c0d55646f6353748003d10f105f1012636f6e746578744265666f7265496e70757480045568656c6c6f080d121b202c3a3c3e444a5d6066686b80820000000000000101000000000000001200000000000000000000000000000088")!
        let mock = AutoOpackConnection()
        let api = makeAPI(mock)
        mock.opackContent["_tiStart"] = ["_tiD": tiData]

        try await api.textSet("world")

        // 帧序列:_tiStop, _tiStart, _tiC(清空), _tiC(输入)。
        expectEqual(mock.sentFrames.count, 4, "textSet 帧数")
        expectEqual(mock.sentCommand(0)?.identifier, "_tiStop", "首帧 _tiStop")
        expectEqual(mock.sentCommand(1)?.identifier, "_tiStart", "次帧 _tiStart")

        let clearEvent = mock.sentCommand(2)
        expectEqual(clearEvent?.identifier, "_tiC", "清空事件命令名")
        expectEqual(clearEvent?.content["_tiV"] as? Int64, 1, "清空 _tiV")
        if let clearPayload = clearEvent?.content["_tiD"] as? Data {
            let p = RTITextInput.readArchiveProperties(clearPayload, paths: [
                ["textOperations", "textToAssert"],
            ])
            expectEqual(p.first as? String, "", "清空 textToAssert 为空串")
        } else {
            expect(false, "清空事件缺少 _tiD")
        }

        let inputEvent = mock.sentCommand(3)
        expectEqual(inputEvent?.identifier, "_tiC", "输入事件命令名")
        if let inputPayload = inputEvent?.content["_tiD"] as? Data {
            let p = RTITextInput.readArchiveProperties(inputPayload, paths: [
                ["textOperations", "keyboardOutput", "insertionText"],
            ])
            expectEqual(p.first as? String, "world", "输入文本")
        } else {
            expect(false, "输入事件缺少 _tiD")
        }

        // textAppend 只发一次 _tiC 输入(不清空)。
        let mock2 = AutoOpackConnection()
        let api2 = makeAPI(mock2)
        mock2.opackContent["_tiStart"] = ["_tiD": tiData]
        try await api2.textAppend("!")
        expectEqual(mock2.sentFrames.count, 3, "textAppend 帧数(无清空)")
        expectEqual(mock2.sentCommand(2)?.identifier, "_tiC", "textAppend 仅输入事件")
    }

    await runSuiteAsync("connect 完整会话") {
        // 真实凭证:ltpk = 设备长期公钥,ltsk = 客户端长期私钥。
        let clientSigning = Curve25519.Signing.PrivateKey()
        let serverSigning = Curve25519.Signing.PrivateKey()
        let clientId = Data("client-id-1234".utf8)
        let atvId = Data("atv-id-5678".utf8)
        let creds = HapCredentials(
            ltpk: serverSigning.publicKey.rawRepresentation,
            ltsk: clientSigning.rawRepresentation,
            atvId: atvId,
            clientId: clientId)

        let mock = AutoOpackConnection()
        let server = PairVerifyServer(serverSigning: serverSigning, credentials: creds)
        mock.authHandler = { ft, payload in server.handle(ft, payload) }
        mock.opackContent["_sessionStart"] = ["_sid": Int64(12345)]

        let srp = SRPAuthHandler(pairingId: clientId)
        let proto = CompanionProtocol(connection: mock, srp: srp)
        let deviceInfo = CompanionDeviceInfo(name: "Test Remote", model: "Mac", identifier: "test-device-id")
        let api = CompanionAPI(protocolLayer: proto, credentials: creds, deviceInfo: deviceInfo)

        try await api.connect()

        // 帧序列: pvStart, pvNext, _systemInfo, _touchStart, _sessionStart, TVRCSessionStart, _tiStart, _interest。
        expectEqual(mock.sentFrames.count, 8, "connect 帧数")
        expectEqual(mock.sentFrames[0].0, .pvStart, "首帧 pvStart")
        expectEqual(mock.sentFrames[1].0, .pvNext, "次帧 pvNext")

        let sysInfo = mock.sentCommand(2)
        expectEqual(sysInfo?.identifier, "_systemInfo", "_systemInfo 命令名")
        expectEqual(sysInfo?.content["_sv"] as? String, "170.18", "_systemInfo _sv")
        expectEqual(sysInfo?.content["_i"] as? String, deviceInfo.identifier, "_systemInfo _i")
        expectEqual(sysInfo?.content["_idsID"] as? String, "client-id-1234", "_systemInfo _idsID")

        expectEqual(mock.sentCommand(3)?.identifier, "_touchStart", "_touchStart 命令名")

        let session = mock.sentCommand(4)
        expectEqual(session?.identifier, "_sessionStart", "_sessionStart 命令名")
        expectEqual(session?.content["_srvT"] as? String, "com.apple.tvremoteservices", "_sessionStart _srvT")
        expect(session?.content["_sid"] is Int64, "_sessionStart 含 _sid")

        expectEqual(mock.sentCommand(5)?.identifier, "TVRCSessionStart", "TVRCSessionStart 命令名")
        expectEqual(mock.sentCommand(6)?.identifier, "_tiStart", "_tiStart 命令名")

        expectEqual(mock.sentFrames[7].0, .eOpack, "订阅帧类型")
        expectEqual(mock.interestEvents.count, 1, "订阅事件数")
        expectEqual((mock.interestEvents[0]["_c"] as? [String: Any])?["_regEvents"] as? [String], ["_iMC"], "订阅 _iMC")
    }
}
