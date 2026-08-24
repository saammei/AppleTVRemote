import Foundation
import CryptoKit
import AppleTVControl

/// 内存 mock 连接:捕获客户端发送的帧,并按脚本回放服务器响应。
final class MockCompanionConnection: CompanionConnection {
    var isConnected = false
    weak var listener: CompanionConnectionListener?
    private(set) var sentFrames: [(FrameType, Data)] = []
    private var scriptedResponses: [(FrameType, Data)] = []

    func connect() async throws { isConnected = true }
    func close() { isConnected = false }

    func send(_ frameType: FrameType, payload: Data) throws {
        sentFrames.append((frameType, payload))
        if !scriptedResponses.isEmpty {
            let (rt, rp) = scriptedResponses.removeFirst()
            listener?.connection(self, didReceive: rt, payload: rp)
        }
    }

    func enableEncryption(outputKey: Data, inputKey: Data) {}

    func enqueue(_ frameType: FrameType, _ payload: Data) {
        scriptedResponses.append((frameType, payload))
    }
}

/// 解包 sent payload(OPACK),提取 _pd 字段并解码 TLV。
func sentTLV(_ payload: Data) -> [UInt8: Data]? {
    guard let (value, _) = OPACK.unpack(payload),
          let dict = value as? [String: Any],
          let pd = dict["_pd"] as? Data else { return nil }
    return TLV8.decode(pd)
}

func runCompanionTests() async {
    runSuite("连接层帧编解码") {
        // 无加密:header 长度字段 3 字节大端。
        let payload = Data([0x01, 0x02, 0x03])
        let frame = try! CompanionFrame.encode(frameType: .uOpack, payload: payload, cipher: nil)
        expectHexEqual([UInt8](frame), [UInt8](Data(hex: "07000003")! + payload), "无加密帧")

        // 解码回原始值。
        guard let (ft, decoded, consumed) = CompanionFrame.decode(from: frame) else {
            expect(false, "decode 返回 nil"); return
        }
        expectEqual(ft, .uOpack, "decode 帧类型")
        expectEqual(decoded, payload, "decode payload")
        expectEqual(consumed, 7, "decode consumed")

        // 缓冲不足返回 nil。
        expectEqual(CompanionFrame.decode(from: Data([0x07, 0x00])) == nil, true, "缓冲不足返回 nil")
    }

    runSuite("连接层加密 round-trip") {
        // 两端:发送方的 outKey == 接收方的 inKey,反之亦然。
        let keyA = Data(repeating: 0x01, count: 32)
        let keyB = Data(repeating: 0x02, count: 32)
        let client = CompanionCipher(outKey: keyA, inKey: keyB)
        let server = CompanionCipher(outKey: keyB, inKey: keyA)

        // client 加密 → server 解密(counter 从 0 独立递增)。
        let msg1 = Data("hello world".utf8)
        let frame1 = try! CompanionFrame.encode(frameType: .pOpack, payload: msg1, cipher: client)
        guard let (ft1, body1, _) = CompanionFrame.decode(from: frame1) else {
            expect(false, "加密帧 decode 失败"); return
        }
        expectEqual(ft1, .pOpack, "加密帧类型")
        expectEqual(body1.count, msg1.count + 16, "加密帧长度含 tag")
        let header1 = frame1.prefix(4)
        let decrypted1 = try! server.decrypt(body1, aad: Data(header1))
        expectEqual(decrypted1, msg1, "加密 round-trip")

        // 第二条消息:nonce 递增,仍能正确解密。
        let msg2 = Data("second".utf8)
        let frame2 = try! CompanionFrame.encode(frameType: .pOpack, payload: msg2, cipher: client)
        let (_, body2, _) = CompanionFrame.decode(from: frame2)!
        let header2 = frame2.prefix(4)
        let decrypted2 = try! server.decrypt(body2, aad: Data(header2))
        expectEqual(decrypted2, msg2, "第二条加密 round-trip")

        // 空 payload 不加密(与 pyatv 一致)。
        let emptyFrame = try! CompanionFrame.encode(frameType: .noOp, payload: Data(), cipher: client)
        expectEqual(emptyFrame, Data(hex: "01000000")!, "空 payload 帧")
    }

    await runSuiteAsync("Pair-Setup 端到端") {
        // 固定输入与 Python 生成器(/tmp/gen_ps_transcript.py)一致。
        let clientSeed = Data(repeating: 0x11, count: 32)
        let verifySeed = Data(repeating: 0x22, count: 32)
        let clientId = Data(hex: "31323334353637382d313233342d313233342d313233342d313233343536373839616263")!
        let atvId = Data(hex: "61626364656661622d636465662d616263642d656661622d636465666162636465666162")!
        let salt = Data(hex: "5555555555555555")!
        let serverB = Data(hex: "19c613dcae31efa50a1a2100e070c39582f24fa771bb9b139299070fef46fbb062c5b19e527a72d63330711113cb30c8b36b18eb9569cc8e39200d6483c0df2af7184ff218d2c71d0fed2efef96c9217e4e6115981eef02c470a5edc91ea4b37117a1311bc7bf300df85cc80e28b972c2bad52307fd017e7071544cd30977f8e5a0381d6a2c826d208fdac2d0c8329bb623fbf60d7a7245256ac169f2b0b615a1f8e7b7e09f9adca4d1c5f04ff74b69b1e51ce3278e8f26579feb58d979ed80bfe022c52a91de9f747be92c11a830c5d5475ee9803fc92e927ead5e99633df5a668ca872ba0bec49bbdd7a328991307e3e1ac908af05be9d4416c0d23aee77edff6b1bd32266d3e7830d4ed66164c04079d9aa4c98bca6101a717d01b29da427d5432ead0e2510fe1812dec592b9b5cafff120f4dda44addfff8204874d439d3779719f5e949c6b5b6048e079db73b1f8dbdcc913b9baca203aa37d0615ea21e48bbe7e67488c7a4211dd9309b2c8a7fbca90f3688e16f6fa333863b9169d26e")!
        let serverM2 = Data(hex: "28b437ceb5e2647f629f0cff2cdd57f8e700255307b50fbd8d842339ee543a92098e8992eacc0e47072b98756bc0e743dfbdea875dfe120a146968ba558a6b8b")!
        let m6 = Data(hex: "80430559a445dbd777b8378010143565136848901bed87d340594903f403cd90eae0ab0bf87909c3b7da240e69366a8bac8d54e955e35579b3faca7b1731c02972a15af5c74e4f65eefce8a51e06499ed28011c5e618a785c14e138366cb013bd6432bd3866b505750cd6d0289ff175abead6cfa81de5b1ef9cb09a2eb04898c3f30a6efb7bbccfcbda0759627abe92ef73223f1a2f17f1e1331")!
        let clientA = Data(hex: "c95341372ca4d0b469f87c0ae37bda635713223b577ef5e8d64a959a54e5395722fea50e71bbd44306055760924a64885805ae13545fcfc7e65f4e7b75c765a112d267f79bffb8353d96ae81cfa64ca7eb687a5dba4cf223b21e1362489ca3e056254b25f610c00643490ea19944f6d3d0872bdcc5fc338bebc8936f30b695924e117f364a4cfc3898eeaa1a4bb98957df8eb046eba3cf42558138ca616a1dc7991426292dd258693bbd4c11816e3064e4a7c536f7255ae61735db25e3cf0349eb8b3e9848d0aa572b0f809d8983f1b280581aba96104422fcf088b698f8d899115a5653cc473e87f5e45552a5a126c8b7fc273bd2cd12bfb15ff3501a572b17608f16c33f6e971081f3af1be37a0a96748f60d204e935f6a5d2a71303aea434b45bcb9ab6b4444208d3fdf7a00c07a3ba2a09b56b578170c78ba1573ca2692406ba8d461e43bb3d160f0024a388d7234236537e29c3604f666c69d7244eae29a0e8b9fa5ee490890e5892973fa535707fbe8f06e90dcbb99c7b39b5eb2b45fb")!
        let clientM = Data(hex: "182df0306d0f839a19bc7b9470b7b35398ff55f24a9389b9c9519f84453a5dc64df23514363aebd7a70d793cbc3d1ec8df8d3897394f5e1d311096eb25b13d34")!
        let atvLtpk = Data(hex: "34b4d9043156cb6dcf0beb0a2949b7559c940d2bcb6dbe8c53a9b30278e3a746")!
        let authPublic = try Curve25519.Signing.PrivateKey(rawRepresentation: clientSeed).publicKey.rawRepresentation

        let srp = SRPAuthHandler(pairingId: clientId)
        let mock = MockCompanionConnection()
        let proto = CompanionProtocol(connection: mock, srp: srp)
        let setup = CompanionPairSetupProcedure(proto, srp)

        // 脚本化服务器响应:M2(salt+B)、M4(proof)、M6(encryptedData)。
        mock.enqueue(.psNext, OPACK.pack([
            "_pd": TLV8.encode([
                (TLV8Tag.salt.rawValue, salt),
                (TLV8Tag.publicKey.rawValue, serverB),
            ]),
            "_pwTy": 1,
        ]))
        mock.enqueue(.psNext, OPACK.pack([
            "_pd": TLV8.encode([
                (TLV8Tag.seqNo.rawValue, Data([0x04])),
                (TLV8Tag.proof.rawValue, serverM2),
            ]),
            "_pwTy": 1,
        ]))
        mock.enqueue(.psNext, OPACK.pack([
            "_pd": TLV8.encode([
                (TLV8Tag.seqNo.rawValue, Data([0x06])),
                (TLV8Tag.encryptedData.rawValue, m6),
            ]),
            "_pwTy": 1,
        ]))

        try await setup.startPairing(authPrivateSeed: clientSeed, verifyPrivateSeed: verifySeed)

        // M1(PS_Start):method=0x00, seqNo=0x01。
        expectEqual(mock.sentFrames.count, 1, "M1 发送后 sent 数")
        expectEqual(mock.sentFrames[0].0, .psStart, "M1 帧类型")
        if let tlv1 = sentTLV(mock.sentFrames[0].1) {
            expectEqual(tlv1[TLV8Tag.method.rawValue], Data([0x00]), "M1 method")
            expectEqual(tlv1[TLV8Tag.seqNo.rawValue], Data([0x01]), "M1 seqNo")
        } else {
            expect(false, "M1 _pd 解析失败")
        }

        let creds = try await setup.finishPairing(pin: "1234")

        // M3(PS_Next):seqNo=0x03, publicKey=A, proof=M(与 Python 逐字节一致)。
        expectEqual(mock.sentFrames.count, 3, "完成配对后 sent 数")
        expectEqual(mock.sentFrames[1].0, .psNext, "M3 帧类型")
        if let tlv3 = sentTLV(mock.sentFrames[1].1) {
            expectEqual(tlv3[TLV8Tag.seqNo.rawValue], Data([0x03]), "M3 seqNo")
            expectHexEqual([UInt8](tlv3[TLV8Tag.publicKey.rawValue] ?? Data()), [UInt8](clientA), "M3 publicKey == A")
            expectHexEqual([UInt8](tlv3[TLV8Tag.proof.rawValue] ?? Data()), [UInt8](clientM), "M3 proof == M")
        } else {
            expect(false, "M3 _pd 解析失败")
        }

        // M5(PS_Next):seqNo=0x05, encryptedData 解密后含 identifier/publicKey/有效签名。
        expectEqual(mock.sentFrames[2].0, .psNext, "M5 帧类型")
        guard let tlv5 = sentTLV(mock.sentFrames[2].1),
              let m5Encrypted = tlv5[TLV8Tag.encryptedData.rawValue] else {
            expect(false, "M5 _pd/encryptedData 解析失败"); return
        }
        expectEqual(tlv5[TLV8Tag.seqNo.rawValue], Data([0x05]), "M5 seqNo")

        // 独立计算 SRP 会话密钥,解密 M5 验证其内容(不逐字节比对,因 Ed25519 签名 nonce 派生不同)。
        guard let srpResult = SRP6a.process(
            username: "Pair-Setup", password: "1234",
            clientPrivateBytes: clientSeed, serverPublicBytes: serverB, salt: salt
        ) else {
            expect(false, "SRP6a 独立计算失败"); return
        }
        let sessionKey = HKDF.sha512(
            ikm: srpResult.sessionKey,
            salt: Data("Pair-Setup-Encrypt-Salt".utf8),
            info: Data("Pair-Setup-Encrypt-Info".utf8))
        let decrypted = try ChaCha20Poly1305.open(
            m5Encrypted, key: sessionKey,
            nonce: ChaCha20Poly1305.nonce8("PS-Msg05"), aad: Data())
        let m5TLV = TLV8.decode(decrypted)
        expectEqual(m5TLV[TLV8Tag.identifier.rawValue], clientId, "M5 identifier")
        expectEqual(m5TLV[TLV8Tag.publicKey.rawValue], authPublic, "M5 publicKey")

        let iosDeviceX = HKDF.sha512(
            ikm: srpResult.sessionKey,
            salt: Data("Pair-Setup-Controller-Sign-Salt".utf8),
            info: Data("Pair-Setup-Controller-Sign-Info".utf8))
        var deviceInfo = Data()
        deviceInfo.append(iosDeviceX)
        deviceInfo.append(clientId)
        deviceInfo.append(authPublic)
        let edPub = try Curve25519.Signing.PublicKey(rawRepresentation: authPublic)
        if let sig = m5TLV[TLV8Tag.signature.rawValue] {
            expect(edPub.isValidSignature(sig, for: deviceInfo), "M5 签名验证")
        } else {
            expect(false, "M5 缺少 signature")
        }

        // 凭证与 Python 生成器一致。
        expectHexEqual([UInt8](creds.ltpk), [UInt8](atvLtpk), "凭证 ltpk")
        expectHexEqual([UInt8](creds.ltsk), [UInt8](clientSeed), "凭证 ltsk == client seed")
        expectHexEqual([UInt8](creds.atvId), [UInt8](atvId), "凭证 atvId")
        expectHexEqual([UInt8](creds.clientId), [UInt8](clientId), "凭证 clientId")
    }
}
