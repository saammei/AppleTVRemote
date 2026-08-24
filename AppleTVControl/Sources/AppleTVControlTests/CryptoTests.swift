import Foundation
import CryptoKit
import AppleTVControl

/// 加密层测试。所有向量来自 pyatv 依赖库(srptools / cryptography)的确定性输出,
/// 用于验证 Swift 实现与 Python 实现逐字节一致。

func runCryptoTests() {
    runSuite("SRP-6a 配对向量") {
        // 输入与 pyatv 测试脚本完全一致(固定 client private 与 salt,避免随机性)
        let clientPrivate = Data(hex: "0f" + String(repeating: "11", count: 31))!
        let serverPublic = Data(hex: "d0" + String(repeating: "ab", count: 383))!
        let salt = Data(hex: "cafe12345678")!

        guard let result = SRP6a.process(
            username: "Pair-Setup", password: "1234",
            clientPrivateBytes: clientPrivate, serverPublicBytes: serverPublic, salt: salt
        ) else {
            expect(false, "SRP process 返回 nil(服务器公钥非法)")
            return
        }

        let expectedK = Data(hex:
            "47281045d732ad22fce56d1245ddec9bb4a6e8e0b7e410b12c9d4e9feecddeb7" +
            "2542d535e452eaad64b24dbf78191498482a5c6c119e2c4a83d78385d17ef793")!
        let expectedM = Data(hex:
            "31befac1ca60b0ba5fbad0f707e26a6728718582709beda86479d6dc7674f3b5" +
            "46618c06b5229971460f68e1ee4009139ed608930e7b05a2db2b3324d20ea6a5")!
        let expectedM2 = Data(hex:
            "fa93fbd783f9f2e132c4c348e62ca8719c26e04af5337fd61e29df1f70150ef9" +
            "8856632463fd2348e757301070ab823d88456c273fd8ba5a70f58a527b412d2e")!

        expectHexEqual([UInt8](result.sessionKey), [UInt8](expectedK), "K (会话密钥)")
        expectHexEqual([UInt8](result.proof), [UInt8](expectedM), "M (证明)")
        expectHexEqual([UInt8](result.proofHash), [UInt8](expectedM2), "M2 (证明哈希)")
    }

    runSuite("TLV8 编解码") {
        // 单条记录
        let single = TLV8.encode([(10, Data("123".utf8))])
        expectHexEqual([UInt8](single), [UInt8](Data(hex: "0a03313233")!), "单条编码")

        // 两条记录(顺序敏感)
        let double = TLV8.encode([(1, Data("111".utf8)), (4, Data("222".utf8))])
        expectHexEqual([UInt8](double), [UInt8](Data(hex: "01033131310403323232")!), "两条编码")

        // 超过 255 字节拆分
        let largeValue = Data(repeating: 0x31, count: 256)
        let large = TLV8.encode([(2, largeValue)])
        let expectedLarge = Data(hex: "02ff")! + Data(repeating: 0x31, count: 255) + Data(hex: "020131")!
        expectHexEqual([UInt8](large), [UInt8](expectedLarge), "大 value 拆分编码")

        // 解码合并
        let decoded = TLV8.decode(large)
        expectEqual(decoded[2], largeValue, "大 value 解码合并")
        expectEqual(TLV8.decode(single)[10], Data("123".utf8), "单条解码")
    }

    runSuite("ChaCha20-Poly1305 (RFC 8439)") {
        let key = Data(hex:
            "808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")!
        let nonce = Data(hex: "070000004041424344454647")!
        let aad = Data(hex: "50515253c0c1c2c3c4c5c6c7")!
        let plaintext = Data(
            "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".utf8
        )
        let expected = Data(hex:
            "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63" +
            "dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b369" +
            "2ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc" +
            "3ff4def08e4b7a9de576d26586cec64b6116" +
            "1ae10b594f09e26a7e902ecbd0600691")!

        do {
            let sealed = try ChaCha20Poly1305.seal(plaintext, key: key, nonce: nonce, aad: aad)
            expectHexEqual([UInt8](sealed), [UInt8](expected), "加密结果")
            let opened = try ChaCha20Poly1305.open(sealed, key: key, nonce: nonce, aad: aad)
            expectEqual(opened, plaintext, "解密往返")
        } catch {
            expect(false, "ChaCha20 异常: \(error)")
        }
    }

    runSuite("HKDF-SHA512") {
        let ikm = Data(repeating: 0x11, count: 32)

        let k1 = HKDF.sha512(
            ikm: ikm,
            salt: Data("Pair-Verify-Encrypt-Salt".utf8),
            info: Data("Pair-Verify-Encrypt-Info".utf8))
        expectHexEqual(
            [UInt8](k1),
            [UInt8](Data(hex: "01966e9fca1aaebb848ccef03d3d74d68b0f0bb95e7f48f4a94365dc01b5a873")!),
            "非空 salt")

        // 空 salt(对应 pyatv 的 SRP_SALT = "")
        let k2 = HKDF.sha512(
            ikm: ikm,
            salt: Data(),
            info: Data("ClientEncrypt-main".utf8))
        expectHexEqual(
            [UInt8](k2),
            [UInt8](Data(hex: "603941a1b8866024490d0aa3b116332f4bab8783d7592cbf80e83c64beb321a6")!),
            "空 salt")
    }

    runSuite("凭证序列化") {
        let creds = HapCredentials(
            ltpk: Data(hex: "aabbccdd")!,
            ltsk: Data(hex: "11223344")!,
            atvId: Data(hex: "deadbeef")!,
            clientId: Data(hex: "cafebabe")!)
        let str = creds.detailString
        expectEqual(str, "aabbccdd:11223344:deadbeef:cafebabe", "detailString")

        let parsed = HapCredentials.parse(str)
        expectEqual(parsed, creds, "parse 往返")
        expectEqual(HapCredentials.parse("bad"), nil, "非法输入返回 nil")
    }

    runSuite("Curve25519 跨语言向量") {
        // 向量来自 cryptography 库的确定性输出(固定 seed),验证 CryptoKit 与 Python 逐字节一致。

        // X25519:seed 0x11*32 / 0x22*32
        let clientSeed = Data(repeating: 0x11, count: 32)
        let serverSeed = Data(repeating: 0x22, count: 32)
        do {
            let ck = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: clientSeed)
            let sk = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: serverSeed)
            expectHexEqual(
                [UInt8](ck.publicKey.rawRepresentation),
                [UInt8](Data(hex: "7b4e909bbe7ffe44c465a220037d608ee35897d31ef972f07f74892cb0f73f13")!),
                "X25519 客户端公钥")
            expectHexEqual(
                [UInt8](sk.publicKey.rawRepresentation),
                [UInt8](Data(hex: "0faa684ed28867b97f4a6a2dee5df8ce974e76b7018e3f22a1c4cf2678570f20")!),
                "X25519 服务器公钥")
            let shared = try ck.sharedSecretFromKeyAgreement(with: sk.publicKey)
            let sharedBytes = shared.withUnsafeBytes { Data($0) }
            expectHexEqual(
                [UInt8](sharedBytes),
                [UInt8](Data(hex: "9e004098efc091d4ec2663b4e9f5cfd4d7064571690b4bea97ab146ab9f35056")!),
                "X25519 shared secret")
        } catch {
            expect(false, "X25519 异常: \(error)")
        }

        // Ed25519:seed 0x33*32。CryptoKit 的 Ed25519 签名 nonce 派生与 RFC 8032
        // 不同(但都是合法签名,已交叉验证互通),因此签名不做逐字节一致断言,
        // 改为验证跨库可验证性:cryptography 的签名能被 CryptoKit 验证。
        let edSeed = Data(repeating: 0x33, count: 32)
        do {
            let edk = try Curve25519.Signing.PrivateKey(rawRepresentation: edSeed)
            let edPub = edk.publicKey
            expectHexEqual(
                [UInt8](edPub.rawRepresentation),
                [UInt8](Data(hex: "17cb79fb2b4120f2b1ec65e4198d6e08b28e813feb01e4a400839b85e18080ce")!),
                "Ed25519 公钥")
            let data = Data((0..<32).map { UInt8($0) })

            // cryptography 对同一 seed/data 的签名(标准 RFC 8032),CryptoKit 应能验证。
            let pySig = Data(hex: "ed9c7cad9f617fc07d4d376123504f1112f0c664d72a12567d50fec5ed6299323a08355ba178b30f28502cb5f94d920de3c81820899845008a13b9a753b93909")!
            expect(edPub.isValidSignature(pySig, for: data), "cryptography 签名被 CryptoKit 验证")

            // CryptoKit 自身签名自验 round-trip。
            let selfSig = try edk.signature(for: data)
            expect(edPub.isValidSignature(selfSig, for: data), "CryptoKit 签名自验")
        } catch {
            expect(false, "Ed25519 异常: \(error)")
        }
    }

    runSuite("Pair-Verify 端到端") {
        // 测试数据由 Python(cryptography)模拟 Apple TV 服务器端生成:
        // 客户端 X25519 seed 0x11*32,服务器 seed 0x22*32,服务器 Ed25519 ltpk seed 0x44*32,
        // 客户端 ltsk seed 0x33*32。PV-Msg02 为服务器加密的 {Identifier, Signature}。
        let clientSeed = Data(repeating: 0x11, count: 32)
        let clientLtskSeed = Data(repeating: 0x33, count: 32)
        let clientId = Data(hex: "31323334353637382d313233342d313233342d313233342d313233343536373839616263")!
        let atvId = Data(hex: "61626364656661622d636465662d616263642d656661622d636465666162636465666162")!
        let serverPub = Data(hex: "0faa684ed28867b97f4a6a2dee5df8ce974e76b7018e3f22a1c4cf2678570f20")!
        let atvLtpkPub = Data(hex: "d759793bbc13a2819a827c76adb6fba8a49aee007f49f2d0992d99b825ad2c48")!
        let pvMsg02 = Data(hex: "5529f341215a86df2f945c64aa6e4b1f8ee51e60b33cd220c7a3a634a5463e64ac7eea8494930cd9348efdf75666f8a58d34c3223281e62747417667c876d05f4b1ca4ff25e9854615930358732b343585e36047b3558d998a6624edb0add661b51abb6201a4042b9baa6462dcf4b1ac726943be589db805")!

        do {
            let handler = SRPAuthHandler(pairingId: clientId)
            try handler.initialize(verifyPrivateSeed: clientSeed)
            let creds = HapCredentials(ltpk: atvLtpkPub, ltsk: clientLtskSeed, atvId: atvId, clientId: clientId)

            // verify1 成功即说明:PV-Msg02 解密正确、identifier 匹配、设备签名验证通过。
            let pvMsg03 = try handler.verify1(credentials: creds, sessionPubKey: serverPub, encrypted: pvMsg02)

            // 独立计算 session_key,解密 PV-Msg03 验证其结构。
            let ck = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: clientSeed)
            let spub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverPub)
            let shared = try ck.sharedSecretFromKeyAgreement(with: spub)
            let sharedBytes = shared.withUnsafeBytes { Data($0) }
            let sessionKey = HKDF.sha512(
                ikm: sharedBytes,
                salt: Data("Pair-Verify-Encrypt-Salt".utf8),
                info: Data("Pair-Verify-Encrypt-Info".utf8))

            let decrypted = try ChaCha20Poly1305.open(
                pvMsg03, key: sessionKey,
                nonce: ChaCha20Poly1305.nonce8("PV-Msg03"), aad: Data())
            let tlv = TLV8.decode(decrypted)
            expectEqual(tlv[TLV8Tag.identifier.rawValue], clientId, "PV-Msg03 identifier == client_id")

            // 验证 PV-Msg03 的签名:device_info = client_pub + client_id + server_pub。
            let clientPub = ck.publicKey.rawRepresentation
            var deviceInfo = Data()
            deviceInfo.append(clientPub)
            deviceInfo.append(clientId)
            deviceInfo.append(serverPub)
            let ltsk = try Curve25519.Signing.PrivateKey(rawRepresentation: clientLtskSeed)
            expect(
                ltsk.publicKey.isValidSignature(tlv[TLV8Tag.signature.rawValue]!, for: deviceInfo),
                "PV-Msg03 签名验证")
        } catch {
            expect(false, "Pair-Verify 异常: \(error)")
        }
    }
}
