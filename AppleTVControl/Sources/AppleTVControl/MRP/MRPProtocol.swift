// MRP 协议层:握手 + 请求/响应派发。
// 对应 pyatv 的 pyatv/protocols/mrp/protocol.py。
//
// 握手序列(start):
//   1. DeviceInfoMessage(必须首条,否则设备不响应)
//   2. 加密:若带凭证则执行 crypto pairing(Pair-Verify,复用 SRPAuthHandler)
//   3. SetConnectionStateMessage(connected,fire-and-forget)
//   4. ClientUpdatesConfigMessage(订阅 now-playing / artwork 等推送)
//   5. GetKeyboardSessionMessage
//
// 请求/响应:普通消息按 identifier(字符串)匹配;crypto pairing 无 identifier,
// 按类型(.cryptoPairingMessage)匹配。未匹配的入站消息(推送)交给 delegate。

import Foundation
import SwiftProtobuf
import os

/// MRP 密钥派生常量(pyatv protocol.py)。
enum MRPKeyInfo {
    static let salt = "MediaRemote-Salt"
    static let outputInfo = "MediaRemote-Write-Encryption-Key"
    static let inputInfo = "MediaRemote-Read-Encryption-Key"
}

/// 客户端(本机)标识信息,用于 DeviceInfoMessage。
public struct MRPDeviceInfo {
    /// 控制器名称(如 "MacBook Remote")。
    public let name: String
    /// 稳定标识(配对 client_id / 随机 UUID),作为 uniqueIdentifier。
    public let identifier: String
    /// 系统版本(如 "23A344")。
    public let osBuild: String
    /// 型号(如 "Mac")。
    public let modelName: String

    public init(name: String, identifier: String, osBuild: String, modelName: String) {
        self.name = name
        self.identifier = identifier
        self.osBuild = osBuild
        self.modelName = modelName
    }
}

public protocol MRPProtocolDelegate: AnyObject {
    /// 收到一条推送/未匹配消息(如 SetStateMessage / UpdateContentItemMessage)。
    func mrpProtocol(_ protocol: MRPProtocol, didReceive message: ProtocolMessageMessage)
}

/// 所有 MRP protobuf 扩展的组合 map,用于解析带扩展字段的 ProtocolMessage。
/// 缺少任一扩展,对应的入站消息会落入 unknownFields,类型化访问器返回默认值。
public let mrpExtensions = SwiftProtobuf.SimpleExtensionMap(
    DeviceInfoMessage_Extensions,
    CryptoPairingMessage_Extensions,
    SetConnectionStateMessage_Extensions,
    ClientUpdatesConfigMessage_Extensions,
    GetKeyboardSessionMessage_Extensions,
    SetStateMessage_Extensions,
    UpdateContentItemMessage_Extensions,
    UpdateContentItemArtworkMessage_Extensions,
    SetArtworkMessage_Extensions,
    SendCommandMessage_Extensions,
    SendCommandResultMessage_Extensions,
    GenericMessage_Extensions,
    NotificationMessage_Extensions,
    UpdateClientMessage_Extensions,
    SetNowPlayingClientMessage_Extensions,
    SetNowPlayingPlayerMessage_Extensions)

public final class MRPProtocol: MRPConnectionListener {
    public let connection: MRPConnection
    public let srp: SRPAuthHandler
    public weak var delegate: MRPProtocolDelegate?

    /// 请求派发键:普通消息按 identifier,配对按类型(无 identifier)。
    private enum RequestKey: Hashable {
        case identifier(String)
        case pairing
    }

    private final class PendingRequest: @unchecked Sendable {
        private let continuation: CheckedContinuation<ProtocolMessageMessage, Error>
        init(_ continuation: CheckedContinuation<ProtocolMessageMessage, Error>) {
            self.continuation = continuation
        }
        func resume(returning value: ProtocolMessageMessage) { continuation.resume(returning: value) }
        func resume(throwing error: Error) { continuation.resume(throwing: error) }
    }

    private final class PendingStore: @unchecked Sendable {
        private var pending: [RequestKey: PendingRequest] = [:]
        private var lock = os_unfair_lock()

        func set(_ id: RequestKey, _ request: PendingRequest) {
            os_unfair_lock_lock(&lock)
            pending[id] = request
            os_unfair_lock_unlock(&lock)
        }

        func remove(_ id: RequestKey) -> PendingRequest? {
            os_unfair_lock_lock(&lock)
            let request = pending.removeValue(forKey: id)
            os_unfair_lock_unlock(&lock)
            return request
        }

        func removeAll() -> [PendingRequest] {
            os_unfair_lock_lock(&lock)
            let all = Array(pending.values)
            pending.removeAll()
            os_unfair_lock_unlock(&lock)
            return all
        }
    }

    private var identifier: UInt64
    private let pending = PendingStore()
    private var isStarted = false

    public init(connection: MRPConnection, srp: SRPAuthHandler) {
        self.connection = connection
        self.srp = srp
        self.identifier = UInt64.random(in: 1..<UInt64(1) << 32)
        connection.listener = self
    }

    // MARK: - 生命周期

    /// 建立连接并完成握手。带凭证时执行 crypto pairing 并启用加密。
    public func start(credentials: HapCredentials?, deviceInfo: MRPDeviceInfo) async throws {
        guard !isStarted else { return }
        isStarted = true
        try await connection.connect()

        // 1. DeviceInfoMessage(必须首条)。
        _ = try await sendAndReceive(
            makeMessage(.deviceInfoMessage, deviceInfo: buildDeviceInfoMessage(deviceInfo)))

        // 2. 加密。
        if let credentials {
            try await pairAndEnableEncryption(credentials: credentials)
        }

        // 3. SetConnectionState(connected)。
        var setConnection = SetConnectionStateMessage()
        setConnection.state = .connected
        try await send(makeMessage(.setConnectionStateMessage, setConnectionState: setConnection))

        // 4. ClientUpdatesConfig(订阅 now-playing / artwork 推送)。
        var config = ClientUpdatesConfigMessage()
        config.artworkUpdates = true
        config.nowPlayingUpdates = true
        config.volumeUpdates = true
        config.keyboardUpdates = true
        config.outputDeviceUpdates = true
        _ = try await sendAndReceive(
            makeMessage(.clientUpdatesConfigMessage, clientUpdatesConfig: config))

        // 5. GetKeyboardSession。
        _ = try await sendAndReceive(makeMessage(.getKeyboardSessionMessage))
    }

    public func stop() {
        for request in pending.removeAll() {
            request.resume(throwing: CompanionError.notConnected)
        }
        connection.close()
    }

    // MARK: - 消息构造

    private func buildDeviceInfoMessage(_ info: MRPDeviceInfo) -> DeviceInfoMessage {
        var msg = DeviceInfoMessage()
        msg.uniqueIdentifier = info.identifier
        msg.name = info.name
        msg.localizedModelName = info.modelName
        msg.systemBuildVersion = info.osBuild
        msg.applicationBundleIdentifier = "com.apple.TVRemote"
        msg.applicationBundleVersion = "344.28"
        msg.protocolVersion = 1
        msg.lastSupportedMessageType = 108
        msg.sharedQueueVersion = 2
        msg.supportsSystemPairing = true
        msg.allowsPairing = true
        msg.supportsAcl = true
        msg.supportsSharedQueue = true
        msg.supportsExtendedMotion = true
        msg.systemMediaApplication = "com.apple.TVMusic"
        msg.deviceClass = .mac
        msg.logicalDeviceCount = 1
        return msg
    }

    /// 打包一个内层消息为 ProtocolMessage(type + 扩展字段)。
    private func makeMessage(
        _ type: ProtocolMessageMessage.TypeEnum,
        deviceInfo: DeviceInfoMessage? = nil,
        cryptoPairing: CryptoPairingMessage? = nil,
        setConnectionState: SetConnectionStateMessage? = nil,
        clientUpdatesConfig: ClientUpdatesConfigMessage? = nil
    ) -> ProtocolMessageMessage {
        var msg = ProtocolMessageMessage()
        msg.type = type
        if let deviceInfo { msg.deviceInfoMessage = deviceInfo }
        if let cryptoPairing { msg.cryptoPairingMessage = cryptoPairing }
        if let setConnectionState { msg.setConnectionStateMessage = setConnectionState }
        if let clientUpdatesConfig { msg.clientUpdatesConfigMessage = clientUpdatesConfig }
        return msg
    }

    // MARK: - 收发

    private func nextIdentifier() -> String {
        identifier += 1
        return String(identifier)
    }

    /// 发送并等待响应。crypto pairing 消息无 identifier,按类型匹配。
    @discardableResult
    private func sendAndReceive(
        _ message: ProtocolMessageMessage,
        matchPairing: Bool = false,
        timeout: TimeInterval = 5
    ) async throws -> ProtocolMessageMessage {
        var message = message
        let key: RequestKey
        if matchPairing {
            key = .pairing
        } else {
            let id = nextIdentifier()
            message.identifier = id
            key = .identifier(id)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let request = PendingRequest(continuation)
            pending.set(key, request)

            do {
                try connection.send(try message.serializedData())
            } catch {
                pending.remove(key)?.resume(throwing: error)
                return
            }

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                pending.remove(key)?.resume(throwing: CompanionError.timeout)
            }
        }
    }

    /// 发送一条消息,不等待响应。
    private func send(_ message: ProtocolMessageMessage) async throws {
        try connection.send(try message.serializedData())
    }

    // MARK: - crypto pairing

    private func pairAndEnableEncryption(credentials: HapCredentials) async throws {
        let (_, publicKey) = try srp.initialize()

        // 1. 发送客户端公钥(seqNo=1),设备回服务端公钥 + 加密数据(seqNo=2)。
        var m1 = CryptoPairingMessage()
        m1.pairingData = TLV8.encode([
            (TLV8Tag.seqNo.rawValue, Data([0x01])),
            (TLV8Tag.publicKey.rawValue, publicKey),
        ])
        let resp1 = try await sendAndReceive(
            makeMessage(.cryptoPairingMessage, cryptoPairing: m1), matchPairing: true)
        let tlv1 = try pairingTLV(from: resp1)
        guard let serverPubKey = tlv1[TLV8Tag.publicKey.rawValue],
              let encrypted = tlv1[TLV8Tag.encryptedData.rawValue] else {
            throw CompanionError.invalidResponse
        }

        // 2. verify1:验证设备并签名客户端信息,发送 seqNo=3。
        let encryptedData = try srp.verify1(
            credentials: credentials, sessionPubKey: serverPubKey, encrypted: encrypted)
        var m3 = CryptoPairingMessage()
        m3.pairingData = TLV8.encode([
            (TLV8Tag.seqNo.rawValue, Data([0x03])),
            (TLV8Tag.encryptedData.rawValue, encryptedData),
        ])
        _ = try await sendAndReceive(
            makeMessage(.cryptoPairingMessage, cryptoPairing: m3), matchPairing: true)

        // 3. 派生输出/输入加密密钥并启用。
        let keys = try srp.verify2(
            salt: MRPKeyInfo.salt,
            outputInfo: MRPKeyInfo.outputInfo,
            inputInfo: MRPKeyInfo.inputInfo)
        connection.enableEncryption(outputKey: keys.outputKey, inputKey: keys.inputKey)
    }

    private func pairingTLV(from message: ProtocolMessageMessage) throws -> [UInt8: Data] {
        let tlv = TLV8.decode(message.cryptoPairingMessage.pairingData)
        if let err = tlv[TLV8Tag.error.rawValue] {
            let text = String(data: err, encoding: .utf8) ?? "<binary>"
            throw CompanionError.authenticationFailed("设备返回错误: \(text)")
        }
        return tlv
    }

    // MARK: - MRPConnectionListener

    public func connection(_ connection: MRPConnection, didReceive data: Data) {
        guard let message = try? ProtocolMessageMessage(
            serializedData: data, extensions: mrpExtensions) else { return }

        // 1. 配对响应(无 identifier,按类型匹配)。
        if message.type == .cryptoPairingMessage {
            if let request = pending.remove(.pairing) {
                request.resume(returning: message)
                return
            }
        }

        // 2. 按 identifier 匹配的响应。
        let id = message.identifier
        if !id.isEmpty, let request = pending.remove(.identifier(id)) {
            request.resume(returning: message)
            return
        }

        // 3. 推送事件交给 delegate。
        delegate?.mrpProtocol(self, didReceive: message)
    }
}
