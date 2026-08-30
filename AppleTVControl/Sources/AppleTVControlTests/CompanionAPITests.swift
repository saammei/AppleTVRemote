// CompanionAPI control-layer tests: verify message structure and response parsing for
// button/media/power/app/subscription commands over the encrypted channel, plus the full
// session initialization sequence of connect() (including Pair-Verify).
//
// An in-memory mock connection (unencrypted) replaces TCP: the mock parses _x/_i in sent
// frames and replays scripted responses. Auth frames (Pair-Verify) are handled by
// PairVerifyServer playing the device side for a real encrypted exchange.

import Foundation
import CryptoKit
import AppleTVControl

/// In-memory mock connection: OPACK commands replay _c keyed by _i (defaulting to an empty _c),
/// and support _em errors; auth frames (PV_*) are delegated to authHandler (PairVerifyServer).
final class AutoOpackConnection: CompanionConnection {
    var isConnected = false
    weak var listener: CompanionConnectionListener?
    private(set) var sentFrames: [(FrameType, Data)] = []

    /// Command response content: _i -> _c.
    var opackContent: [String: [String: Any]] = [:]
    /// Command errors: _i -> error message (returned as _em).
    var opackErrors: [String: String] = [:]
    /// Auth frame handler (for connect tests, plays the device side).
    var authHandler: ((FrameType, Data) -> (FrameType, Data)?)?
    /// Received _interest events (fire-and-forget, no reply).
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
        // _interest is an event; no response is expected.
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

    /// Unpacks frame at index, returning (_i, _c, _t).
    func sentCommand(_ index: Int) -> (identifier: String, content: [String: Any], type: Int64)? {
        guard index < sentFrames.count,
              let (value, _) = OPACK.unpack(sentFrames[index].1),
              let dict = value as? [String: Any],
              let id = dict["_i"] as? String else { return nil }
        return (id, dict["_c"] as? [String: Any] ?? [:], dict["_t"] as? Int64 ?? 0)
    }
}

/// Plays the device-side Pair-Verify server: completes a real encrypted exchange with the client (CompanionAPI.connect).
final class PairVerifyServer {
    private let serverSigning: Curve25519.Signing.PrivateKey  // device long-term signing key (ltpk)
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
        // The client's M3 is already encrypted by the client's verify1; here we just return an
        // empty confirmation (the client doesn't validate this response body).
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
    await runSuiteAsync("button press") {
        let mock = AutoOpackConnection()
        let api = makeAPI(mock)

        try await api.press(.up)

        expectEqual(mock.sentFrames.count, 2, "press sends 2 frames")
        let down = mock.sentCommand(0)
        expectEqual(down?.identifier, "_hidC", "press frame command name")
        expectEqual(down?.content["_hBtS"] as? Int64, 1, "press _hBtS")
        expectEqual(down?.content["_hidC"] as? Int64, HidCommand.up.rawValue, "press _hidC")
        let up = mock.sentCommand(1)
        expectEqual(up?.identifier, "_hidC", "release frame command name")
        expectEqual(up?.content["_hBtS"] as? Int64, 2, "release _hBtS")
        expectEqual(up?.content["_hidC"] as? Int64, HidCommand.up.rawValue, "release _hidC")
    }

    await runSuiteAsync("media commands") {
        let mock = AutoOpackConnection()
        let api = makeAPI(mock)

        _ = try await api.mediaCommand(.play)
        expectEqual(mock.sentCommand(0)?.identifier, "_mcc", "play command name")
        expectEqual(mock.sentCommand(0)?.content["_mcc"] as? Int64, MediaControlCommand.play.rawValue, "play _mcc")
    }

    await runSuiteAsync("volume / skip forward") {
        let mock = AutoOpackConnection()
        let api = makeAPI(mock)

        try await api.setVolume(0.5)
        expectEqual(mock.sentCommand(0)?.content["_mcc"] as? Int64, MediaControlCommand.setVolume.rawValue, "volume _mcc")
        expectEqual(mock.sentCommand(0)?.content["_vol"] as? Double, 0.5, "volume _vol")

        try await api.skip(seconds: 10)
        expectEqual(mock.sentCommand(1)?.content["_mcc"] as? Int64, MediaControlCommand.skipBy.rawValue, "skip forward _mcc")
        expectEqual(mock.sentCommand(1)?.content["_skpS"] as? Double, 10, "skip forward _skpS")
    }

    await runSuiteAsync("power") {
        let mock = AutoOpackConnection()
        let api = makeAPI(mock)

        try await api.turnOn()
        expectEqual(mock.sentCommand(0)?.content["_hidC"] as? Int64, HidCommand.wake.rawValue, "wake button")
        try await api.turnOff()
        expectEqual(mock.sentCommand(1)?.content["_hidC"] as? Int64, HidCommand.sleep.rawValue, "sleep button")
    }

    await runSuiteAsync("app list") {
        let mock = AutoOpackConnection()
        let api = makeAPI(mock)
        mock.opackContent["FetchLaunchableApplicationsEvent"] = [
            "com.apple.TVApp": "TV",
            "com.apple.Arcade": "Arcade",
        ]

        let apps = try await api.appList()

        expectEqual(mock.sentCommand(0)?.identifier, "FetchLaunchableApplicationsEvent", "app list command name")
        expectEqual(apps["com.apple.TVApp"], "TV", "app 1")
        expectEqual(apps["com.apple.Arcade"], "Arcade", "app 2")
    }

    await runSuiteAsync("launch app") {
        let mock = AutoOpackConnection()
        let api = makeAPI(mock)

        try await api.launchApp("com.apple.TVApp")

        expectEqual(mock.sentCommand(0)?.identifier, "_launchApp", "launch command name")
        expectEqual(mock.sentCommand(0)?.content["_bundleID"] as? String, "com.apple.TVApp", "launch bundleID")
    }

    await runSuiteAsync("fetch system state") {
        let mock = AutoOpackConnection()
        let api = makeAPI(mock)
        mock.opackContent["FetchAttentionState"] = ["state": Int64(SystemStatus.awake.rawValue)]

        let state = try await api.fetchAttentionState()

        expectEqual(mock.sentCommand(0)?.identifier, "FetchAttentionState", "state command name")
        expectEqual(state, .awake, "state value")
    }

    await runSuiteAsync("event subscribe / unsubscribe") {
        let mock = AutoOpackConnection()
        let api = makeAPI(mock)

        try api.subscribeEvent("_iMC")
        try api.unsubscribeEvent("_iMC")

        expectEqual(mock.interestEvents.count, 2, "subscription event count")
        let ev0 = mock.interestEvents[0]
        expectEqual(ev0["_t"] as? Int64, CompanionMessageType.event.rawValue, "subscription is an event frame")
        expectEqual((ev0["_c"] as? [String: Any])?["_regEvents"] as? [String], ["_iMC"], "subscribe _regEvents")
        let ev1 = mock.interestEvents[1]
        expectEqual((ev1["_c"] as? [String: Any])?["_deregEvents"] as? [String], ["_iMC"], "unsubscribe _deregEvents")
    }

    await runSuiteAsync("command error _em") {
        let mock = AutoOpackConnection()
        let api = makeAPI(mock)
        mock.opackErrors["_hidC"] = "button press failed"

        var thrown: CompanionError?
        do {
            try await api.press(.select)
        } catch let error as CompanionError {
            thrown = error
        } catch {}

        guard let thrown else {
            expect(false, "no CompanionError thrown"); return
        }
        if case .protocolError(let text) = thrown {
            expectEqual(text, "button press failed", "error text")
        } else {
            expect(false, "error type is not protocolError")
        }
    }

    await runSuiteAsync("text input textSet / textAppend / textClear") {
        // _tiD returned by _tiStart (consistent with pyatv): sessionUUID = 0x00..0x0F, current text "hello".
        let tiData = Data(hex: "62706c6973743030d2010203085424746f7058246f626a65637473d2040506075b73657373696f6e555549445d646f63756d656e74537461746580018002a5090a0b0e1155246e756c6c4f1010000102030405060708090a0b0c0d0e0fd10c0d55646f6353748003d10f105f1012636f6e746578744265666f7265496e70757480045568656c6c6f080d121b202c3a3c3e444a5d6066686b80820000000000000101000000000000001200000000000000000000000000000088")!
        let mock = AutoOpackConnection()
        let api = makeAPI(mock)
        mock.opackContent["_tiStart"] = ["_tiD": tiData]

        try await api.textSet("world")

        // Frame sequence: _tiStop, _tiStart, _tiC (clear), _tiC (input).
        expectEqual(mock.sentFrames.count, 4, "textSet frame count")
        expectEqual(mock.sentCommand(0)?.identifier, "_tiStop", "first frame _tiStop")
        expectEqual(mock.sentCommand(1)?.identifier, "_tiStart", "second frame _tiStart")

        let clearEvent = mock.sentCommand(2)
        expectEqual(clearEvent?.identifier, "_tiC", "clear event command name")
        expectEqual(clearEvent?.content["_tiV"] as? Int64, 1, "clear _tiV")
        if let clearPayload = clearEvent?.content["_tiD"] as? Data {
            let p = RTITextInput.readArchiveProperties(clearPayload, paths: [
                ["textOperations", "textToAssert"],
            ])
            expectEqual(p.first as? String, "", "clear textToAssert is empty")
        } else {
            expect(false, "clear event missing _tiD")
        }

        let inputEvent = mock.sentCommand(3)
        expectEqual(inputEvent?.identifier, "_tiC", "input event command name")
        if let inputPayload = inputEvent?.content["_tiD"] as? Data {
            let p = RTITextInput.readArchiveProperties(inputPayload, paths: [
                ["textOperations", "keyboardOutput", "insertionText"],
            ])
            expectEqual(p.first as? String, "world", "input text")
        } else {
            expect(false, "input event missing _tiD")
        }

        // textAppend sends only one _tiC input (no clear).
        let mock2 = AutoOpackConnection()
        let api2 = makeAPI(mock2)
        mock2.opackContent["_tiStart"] = ["_tiD": tiData]
        try await api2.textAppend("!")
        expectEqual(mock2.sentFrames.count, 3, "textAppend frame count (no clear)")
        expectEqual(mock2.sentCommand(2)?.identifier, "_tiC", "textAppend only sends input event")
    }

    await runSuiteAsync("connect full session") {
        // Real credentials: ltpk = device long-term public key, ltsk = client long-term private key.
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

        // Frame sequence: pvStart, pvNext, _systemInfo, _touchStart, _sessionStart, TVRCSessionStart, _tiStart, _interest.
        expectEqual(mock.sentFrames.count, 8, "connect frame count")
        expectEqual(mock.sentFrames[0].0, .pvStart, "first frame pvStart")
        expectEqual(mock.sentFrames[1].0, .pvNext, "second frame pvNext")

        let sysInfo = mock.sentCommand(2)
        expectEqual(sysInfo?.identifier, "_systemInfo", "_systemInfo command name")
        expectEqual(sysInfo?.content["_sv"] as? String, "170.18", "_systemInfo _sv")
        expectEqual(sysInfo?.content["_i"] as? String, deviceInfo.identifier, "_systemInfo _i")
        expectEqual(sysInfo?.content["_idsID"] as? String, "client-id-1234", "_systemInfo _idsID")

        expectEqual(mock.sentCommand(3)?.identifier, "_touchStart", "_touchStart command name")

        let session = mock.sentCommand(4)
        expectEqual(session?.identifier, "_sessionStart", "_sessionStart command name")
        expectEqual(session?.content["_srvT"] as? String, "com.apple.tvremoteservices", "_sessionStart _srvT")
        expect(session?.content["_sid"] is Int64, "_sessionStart includes _sid")

        expectEqual(mock.sentCommand(5)?.identifier, "TVRCSessionStart", "TVRCSessionStart command name")
        expectEqual(mock.sentCommand(6)?.identifier, "_tiStart", "_tiStart command name")

        expectEqual(mock.sentFrames[7].0, .eOpack, "subscription frame type")
        expectEqual(mock.interestEvents.count, 1, "subscription event count")
        expectEqual((mock.interestEvents[0]["_c"] as? [String: Any])?["_regEvents"] as? [String], ["_iMC"], "subscribe _iMC")
    }
}
