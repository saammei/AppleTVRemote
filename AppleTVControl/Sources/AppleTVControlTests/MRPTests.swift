// MRP metadata layer tests: Variant encoding/decoding, MRPCipher, protobuf extension serialization,
// full handshake (DeviceInfo → crypto pairing → SetConnectionState → ClientUpdatesConfig
// → GetKeyboardSession), and the now-playing metadata cache plus artwork cache (push-driven).
//
// An in-memory mock connection replaces TCP: the mock parses sent protobuf frames and replays
// scripted responses; crypto pairing is handled by MrpPairVerifyServer playing the device side
// for a real encrypted exchange.

import Foundation
import CryptoKit
import AppleTVControl

/// In-memory mock connection: parses sent ProtocolMessages and replays scripted responses
/// via responseHandler; non-pairing responses echo the identifier so sendAndReceive matches.
final class AutoMRPConnection: MRPConnection {
    var isConnected = false
    weak var listener: MRPConnectionListener?
    private(set) var sentMessages: [ProtocolMessageMessage] = []

    /// Scripted response: request message -> response message (nil means no response).
    var responseHandler: ((ProtocolMessageMessage) -> ProtocolMessageMessage?)?

    func connect() async throws { isConnected = true }
    func close() { isConnected = false }
    func enableEncryption(outputKey: Data, inputKey: Data) {}

    func send(_ data: Data) throws {
        guard let msg = try? ProtocolMessageMessage(serializedData: data, extensions: mrpExtensions) else {
            return
        }
        sentMessages.append(msg)
        guard var response = responseHandler?(msg) else { return }
        // Non-pairing messages echo the identifier so sendAndReceive matches (pairing messages have no identifier).
        if response.type != .cryptoPairingMessage && response.identifier.isEmpty {
            response.identifier = msg.identifier
        }
        listener?.connection(self, didReceive: try! response.serializedData())
    }
}

/// Plays the device-side MRP crypto pairing server (Pair-Verify wrapped in protobuf).
final class MrpPairVerifyServer {
    private let serverSigning: Curve25519.Signing.PrivateKey
    private let credentials: HapCredentials

    init(serverSigning: Curve25519.Signing.PrivateKey, credentials: HapCredentials) {
        self.serverSigning = serverSigning
        self.credentials = credentials
    }

    func handle(_ request: ProtocolMessageMessage) -> ProtocolMessageMessage? {
        guard request.type == .cryptoPairingMessage else { return nil }
        let tlv = TLV8.decode(request.cryptoPairingMessage.pairingData)
        let seqNo = tlv[TLV8Tag.seqNo.rawValue]?.first ?? 0
        switch seqNo {
        case 1: return handleM1(tlv)
        case 3: return emptyPairingResponse()
        default: return nil
        }
    }

    private func handleM1(_ tlv: [UInt8: Data]) -> ProtocolMessageMessage? {
        guard let clientPubKey = tlv[TLV8Tag.publicKey.rawValue],
              let clientPublic = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientPubKey) else {
            return nil
        }

        let vp = Curve25519.KeyAgreement.PrivateKey()
        let serverPubKey = vp.publicKey.rawRepresentation
        let shared = try! vp.sharedSecretFromKeyAgreement(with: clientPublic)
        let sharedBytes = shared.withUnsafeBytes { Data($0) }
        let sk = HKDF.sha512(
            ikm: sharedBytes,
            salt: Data("Pair-Verify-Encrypt-Salt".utf8),
            info: Data("Pair-Verify-Encrypt-Info".utf8))

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

        var m2 = CryptoPairingMessage()
        m2.pairingData = responsePD
        return pairingMessage(m2)
    }

    private func pairingMessage(_ inner: CryptoPairingMessage) -> ProtocolMessageMessage {
        var resp = ProtocolMessageMessage()
        resp.type = .cryptoPairingMessage
        resp.cryptoPairingMessage = inner
        return resp
    }

    private func emptyPairingResponse() -> ProtocolMessageMessage {
        var resp = ProtocolMessageMessage()
        resp.type = .cryptoPairingMessage
        return resp
    }
}

func runMRPTests() async {
    runSuite("Variant encoding/decoding") {
        let cases: [(Int, [UInt8])] = [
            (0, [0x00]),
            (1, [0x01]),
            (127, [0x7F]),
            (128, [0x80, 0x01]),
            (300, [0xAC, 0x02]),
            (16384, [0x80, 0x80, 0x01]),
        ]
        for (value, expected) in cases {
            expectHexEqual([UInt8](Variant.encode(value)), expected, "Variant.encode(\(value))")
        }
        for value in [0, 1, 127, 128, 300, 16384, 1_000_000, Int(Int32.max)] {
            guard let (decoded, remaining) = Variant.decode(Variant.encode(value)) else {
                expect(false, "Variant.decode(\(value)) returned nil"); continue
            }
            expectEqual(decoded, value, "Variant round-trip \(value)")
            expectEqual(remaining.count, 0, "Variant round-trip no remainder \(value)")
        }
    }

    runSuite("MRPCipher nonce / round-trip") {
        let key = Data(repeating: 0x42, count: 32)
        let cipher = MRPCipher(outKey: key, inKey: key)

        expectHexEqual(
            [UInt8](ChaCha20Poly1305.nonceCounter8(0)),
            [UInt8](repeating: 0, count: 12),
            "counter 0 nonce all zeros")
        expectHexEqual(
            [UInt8](ChaCha20Poly1305.nonceCounter8(1)),
            [0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0],
            "counter 1 nonce (4 zero bytes + 8-byte little-endian)")

        let plaintext = Data("hello mrp".utf8)
        let encrypted = try! cipher.encrypt(plaintext)
        expect(encrypted != plaintext, "ciphertext differs from plaintext")
        expectEqual(try! cipher.decrypt(encrypted), plaintext, "MRPCipher round-trip")
    }

    runSuite("MRP protobuf extension serialization") {
        var device = DeviceInfoMessage()
        device.uniqueIdentifier = "abc-123"
        device.name = "Test Remote"
        device.protocolVersion = 1
        device.deviceClass = .mac

        var outer = ProtocolMessageMessage()
        outer.type = .deviceInfoMessage
        outer.identifier = "17"
        outer.deviceInfoMessage = device

        let data = try! outer.serializedData()
        let parsed = try! ProtocolMessageMessage(serializedData: data, extensions: mrpExtensions)

        expectEqual(parsed.type, .deviceInfoMessage, "type")
        expectEqual(parsed.identifier, "17", "identifier")
        expectEqual(parsed.deviceInfoMessage.uniqueIdentifier, "abc-123", "deviceInfo uniqueIdentifier")
        expectEqual(parsed.deviceInfoMessage.name, "Test Remote", "deviceInfo name")
        expectEqual(parsed.deviceInfoMessage.deviceClass, .mac, "deviceInfo deviceClass")
    }

    await runSuiteAsync("now-playing metadata cache") {
        let mock = AutoMRPConnection()
        let srp = SRPAuthHandler(pairingId: Data("client-id".utf8))
        let proto = MRPProtocol(connection: mock, srp: srp)
        let api = MRPAPI(protocolLayer: proto)

        // SetStateMessage: playback state + now-playing info.
        var info = NowPlayingInfo()
        info.title = "Test Song"
        info.artist = "Some Artist"
        info.album = "Some Album"
        info.duration = 240.0
        info.elapsedTime = 30.0
        var setState = SetStateMessage()
        setState.nowPlayingInfo = info
        setState.playbackState = .playing

        var msg = ProtocolMessageMessage()
        msg.type = .setStateMessage
        msg.setStateMessage = setState
        api.mrpProtocol(proto, didReceive: msg)

        // ContentItem: more complete track metadata (mediaType / mediaSubType).
        var meta = ContentItemMetadata()
        meta.title = "Full Title"
        meta.trackArtistName = "Full Artist"
        meta.albumName = "Full Album"
        meta.duration = 200.0
        meta.mediaType = .audio
        meta.mediaSubType = .music
        var item = ContentItem()
        item.identifier = "content-1"
        item.metadata = meta
        var update = UpdateContentItemMessage()
        update.contentItems = [item]
        var updateMsg = ProtocolMessageMessage()
        updateMsg.type = .updateContentItemMessage
        updateMsg.updateContentItemMessage = update
        api.mrpProtocol(proto, didReceive: updateMsg)

        let np = api.nowPlaying()
        expectEqual(np.title, "Full Title", "title prefers ContentItem")
        expectEqual(np.artist, "Full Artist", "artist from ContentItem")
        expectEqual(np.album, "Full Album", "album from ContentItem")
        expectEqual(np.duration, 200.0, "duration from ContentItem")
        expectEqual(np.position, 30.0, "position from NowPlayingInfo.elapsedTime")
        expectEqual(np.playbackState, .playing, "playbackState")
        expectEqual(np.mediaType, "Music", "mediaType maps to Music")
    }

    await runSuiteAsync("now-playing falls back to NowPlayingInfo without ContentItem") {
        let mock = AutoMRPConnection()
        let srp = SRPAuthHandler(pairingId: Data("client-id".utf8))
        let proto = MRPProtocol(connection: mock, srp: srp)
        let api = MRPAPI(protocolLayer: proto)

        var info = NowPlayingInfo()
        info.title = "Title Only"
        info.artist = "Artist Only"
        var setState = SetStateMessage()
        setState.nowPlayingInfo = info
        setState.playbackState = .paused

        var msg = ProtocolMessageMessage()
        msg.type = .setStateMessage
        msg.setStateMessage = setState
        api.mrpProtocol(proto, didReceive: msg)

        let np = api.nowPlaying()
        expectEqual(np.title, "Title Only", "fallback title")
        expectEqual(np.artist, "Artist Only", "fallback artist")
        expectEqual(np.mediaType, nil, "mediaType is nil without ContentItem")
        expectEqual(np.playbackState, .paused, "paused")
    }

    await runSuiteAsync("artwork cache") {
        let mock = AutoMRPConnection()
        let srp = SRPAuthHandler(pairingId: Data("client-id".utf8))
        let proto = MRPProtocol(connection: mock, srp: srp)
        let api = MRPAPI(protocolLayer: proto)

        // Feed a content item first (establishing the identifier association).
        var item = ContentItem()
        item.identifier = "content-1"
        var update = UpdateContentItemMessage()
        update.contentItems = [item]
        var updateMsg = ProtocolMessageMessage()
        updateMsg.type = .updateContentItemMessage
        updateMsg.updateContentItemMessage = update
        api.mrpProtocol(proto, didReceive: updateMsg)

        // Then feed artwork (matched by identifier).
        var artworkItem = ContentItem()
        artworkItem.identifier = "content-1"
        artworkItem.artworkData = Data("jpeg-1".utf8)
        var artworkUpdate = UpdateContentItemArtworkMessage()
        artworkUpdate.contentItems = [artworkItem]
        var artworkMsg = ProtocolMessageMessage()
        artworkMsg.type = .updateContentItemArtworkMessage
        artworkMsg.updateContentItemArtworkMessage = artworkUpdate
        api.mrpProtocol(proto, didReceive: artworkMsg)

        expectEqual(api.artwork(), Data("jpeg-1".utf8), "artwork matched by identifier")

        // SetArtworkMessage as fallback.
        var setArtwork = SetArtworkMessage()
        setArtwork.jpegData = Data("jpeg-2".utf8)
        var setArtworkMsg = ProtocolMessageMessage()
        setArtworkMsg.type = .setArtworkMessage
        setArtworkMsg.setArtworkMessage = setArtwork
        api.mrpProtocol(proto, didReceive: setArtworkMsg)

        expectEqual(api.artwork(), Data("jpeg-1".utf8), "identifier match takes precedence over SetArtwork")
    }

    await runSuiteAsync("MRP full handshake") {
        let clientSigning = Curve25519.Signing.PrivateKey()
        let serverSigning = Curve25519.Signing.PrivateKey()
        let clientId = Data("client-id-1234".utf8)
        let atvId = Data("atv-id-5678".utf8)
        let creds = HapCredentials(
            ltpk: serverSigning.publicKey.rawRepresentation,
            ltsk: clientSigning.rawRepresentation,
            atvId: atvId,
            clientId: clientId)

        let mock = AutoMRPConnection()
        let pairingServer = MrpPairVerifyServer(serverSigning: serverSigning, credentials: creds)
        mock.responseHandler = { request in
            switch request.type {
            case .cryptoPairingMessage:
                return pairingServer.handle(request)
            case .deviceInfoMessage:
                var resp = ProtocolMessageMessage()
                resp.type = .deviceInfoMessage
                var info = DeviceInfoMessage()
                info.name = "Apple TV"
                resp.deviceInfoMessage = info
                return resp
            case .clientUpdatesConfigMessage:
                var resp = ProtocolMessageMessage()
                resp.type = .clientUpdatesConfigMessage
                return resp
            case .getKeyboardSessionMessage:
                var resp = ProtocolMessageMessage()
                resp.type = .getKeyboardSessionMessage
                resp.getKeyboardSessionMessage = "session-1"
                return resp
            default:
                return nil
            }
        }

        let srp = SRPAuthHandler(pairingId: clientId)
        let proto = MRPProtocol(connection: mock, srp: srp)
        let deviceInfo = MRPDeviceInfo(
            name: "Test Remote", identifier: "test-device-id", osBuild: "23A344", modelName: "Mac")
        let api = MRPAPI(protocolLayer: proto)

        try await api.connect(credentials: creds, deviceInfo: deviceInfo)

        // Sequence: deviceInfo, cryptoPairing M1, cryptoPairing M3, setConnectionState, clientUpdatesConfig, getKeyboardSession.
        expectEqual(mock.sentMessages.count, 6, "handshake message count")
        expectEqual(mock.sentMessages[0].type, .deviceInfoMessage, "first deviceInfo")
        expectEqual(mock.sentMessages[1].type, .cryptoPairingMessage, "second crypto pairing M1")
        expectEqual(mock.sentMessages[2].type, .cryptoPairingMessage, "third crypto pairing M3")
        expectEqual(mock.sentMessages[3].type, .setConnectionStateMessage, "setConnectionState")
        expectEqual(mock.sentMessages[4].type, .clientUpdatesConfigMessage, "clientUpdatesConfig")
        expectEqual(mock.sentMessages[5].type, .getKeyboardSessionMessage, "getKeyboardSession")

        expectEqual(mock.sentMessages[0].deviceInfoMessage.uniqueIdentifier, "test-device-id", "deviceInfo identifier")
        expectEqual(mock.sentMessages[3].setConnectionStateMessage.state, .connected, "connection state connected")
        expectEqual(mock.sentMessages[4].clientUpdatesConfigMessage.nowPlayingUpdates, true, "subscribes to now-playing updates")
    }
}
