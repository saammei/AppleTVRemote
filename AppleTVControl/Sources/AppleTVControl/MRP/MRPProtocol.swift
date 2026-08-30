// MRP protocol layer: handshake + request/response dispatch.
// Corresponds to pyatv's pyatv/protocols/mrp/protocol.py.
//
// Handshake sequence (start):
//   1. DeviceInfoMessage (must be first, otherwise the device does not respond)
//   2. Encryption: if credentials are present, run crypto pairing (Pair-Verify, reusing SRPAuthHandler)
//   3. SetConnectionStateMessage (connected, fire-and-forget)
//   4. ClientUpdatesConfigMessage (subscribe to now-playing / artwork pushes, etc.)
//   5. GetKeyboardSessionMessage
//
// Request/response: regular messages match by identifier (string); crypto pairing has no identifier,
// so it matches by type (.cryptoPairingMessage). Inbound messages that match nothing (pushes) are
// handed to the delegate.

import Foundation
import SwiftProtobuf
import os

/// MRP key derivation constants (pyatv protocol.py).
enum MRPKeyInfo {
    static let salt = "MediaRemote-Salt"
    static let outputInfo = "MediaRemote-Write-Encryption-Key"
    static let inputInfo = "MediaRemote-Read-Encryption-Key"
}

/// Client (this device) identity information, used for DeviceInfoMessage.
public struct MRPDeviceInfo {
    /// Controller name (e.g. "MacBook Remote").
    public let name: String
    /// Stable identifier (pairing client_id / random UUID), used as uniqueIdentifier.
    public let identifier: String
    /// System build version (e.g. "23A344").
    public let osBuild: String
    /// Model name (e.g. "Mac").
    public let modelName: String

    public init(name: String, identifier: String, osBuild: String, modelName: String) {
        self.name = name
        self.identifier = identifier
        self.osBuild = osBuild
        self.modelName = modelName
    }
}

public protocol MRPProtocolDelegate: AnyObject {
    /// Received a push/unmatched message (e.g. SetStateMessage / UpdateContentItemMessage).
    func mrpProtocol(_ protocol: MRPProtocol, didReceive message: ProtocolMessageMessage)
}

/// Combined map of all MRP protobuf extensions, used to parse ProtocolMessage with extension fields.
/// If any extension is missing, the corresponding inbound message falls into unknownFields and the
/// typed accessors return default values.
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

    /// Request dispatch key: regular messages by identifier, pairing by type (no identifier).
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

    /// Disconnect callback (triggered by the connection layer, may come from any thread).
    public var onDisconnect: (() -> Void)?

    private var identifier: UInt64
    private var identifierLock = os_unfair_lock()
    private let pending = PendingStore()
    private var isStarted = false

    public init(connection: MRPConnection, srp: SRPAuthHandler) {
        self.connection = connection
        self.srp = srp
        self.identifier = UInt64.random(in: 1..<UInt64(1) << 32)
        connection.listener = self
    }

    // MARK: - Lifecycle

    /// Establishes the connection and completes the handshake. Runs crypto pairing and enables
    /// encryption when credentials are present.
    public func start(credentials: HapCredentials?, deviceInfo: MRPDeviceInfo) async throws {
        guard !isStarted else { return }
        isStarted = true
        try await connection.connect()

        // 1. DeviceInfoMessage (must be first).
        _ = try await sendAndReceive(
            makeMessage(.deviceInfoMessage, deviceInfo: buildDeviceInfoMessage(deviceInfo)))

        // 2. Encryption.
        if let credentials {
            try await pairAndEnableEncryption(credentials: credentials)
        }

        // 3. SetConnectionState (connected).
        var setConnection = SetConnectionStateMessage()
        setConnection.state = .connected
        try await send(makeMessage(.setConnectionStateMessage, setConnectionState: setConnection))

        // 4. ClientUpdatesConfig (subscribe to now-playing / artwork pushes).
        var config = ClientUpdatesConfigMessage()
        config.artworkUpdates = true
        config.nowPlayingUpdates = true
        config.volumeUpdates = true
        config.keyboardUpdates = true
        config.outputDeviceUpdates = true
        _ = try await sendAndReceive(
            makeMessage(.clientUpdatesConfigMessage, clientUpdatesConfig: config))

        // 5. GetKeyboardSession.
        _ = try await sendAndReceive(makeMessage(.getKeyboardSessionMessage))
    }

    public func stop() {
        for request in pending.removeAll() {
            request.resume(throwing: CompanionError.notConnected)
        }
        connection.close()
    }

    // MARK: - Message construction

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

    /// Wraps an inner message as a ProtocolMessage (type + extension fields).
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

    // MARK: - Send/receive

    private func nextIdentifier() -> String {
        os_unfair_lock_lock(&identifierLock)
        identifier += 1
        let id = String(identifier)
        os_unfair_lock_unlock(&identifierLock)
        return id
    }

    /// Sends and waits for the response. Crypto pairing messages have no identifier, so they are matched by type.
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

    /// Sends a message without waiting for a response.
    private func send(_ message: ProtocolMessageMessage) async throws {
        try connection.send(try message.serializedData())
    }

    // MARK: - Crypto pairing

    private func pairAndEnableEncryption(credentials: HapCredentials) async throws {
        let (_, publicKey) = try srp.initialize()

        // 1. Send the client public key (seqNo=1); the device replies with its server public key + encrypted data (seqNo=2).
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

        // 2. verify1: verify the device and sign the client information, send seqNo=3.
        let encryptedData = try srp.verify1(
            credentials: credentials, sessionPubKey: serverPubKey, encrypted: encrypted)
        var m3 = CryptoPairingMessage()
        m3.pairingData = TLV8.encode([
            (TLV8Tag.seqNo.rawValue, Data([0x03])),
            (TLV8Tag.encryptedData.rawValue, encryptedData),
        ])
        _ = try await sendAndReceive(
            makeMessage(.cryptoPairingMessage, cryptoPairing: m3), matchPairing: true)

        // 3. Derive the output/input encryption keys and enable them.
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
            throw CompanionError.authenticationFailed("Device returned an error: \(text)")
        }
        return tlv
    }

    // MARK: - MRPConnectionListener

    public func connection(_ connection: MRPConnection, didReceive data: Data) {
        guard let message = try? ProtocolMessageMessage(
            serializedData: data, extensions: mrpExtensions) else { return }

        // 1. Pairing response (no identifier, matched by type).
        if message.type == .cryptoPairingMessage {
            if let request = pending.remove(.pairing) {
                request.resume(returning: message)
                return
            }
        }

        // 2. Response matched by identifier.
        let id = message.identifier
        if !id.isEmpty, let request = pending.remove(.identifier(id)) {
            request.resume(returning: message)
            return
        }

        // 3. Push events are handed to the delegate.
        delegate?.mrpProtocol(self, didReceive: message)
    }

    public func connectionDidClose(_ connection: MRPConnection) {
        // On disconnect: fail all pending requests with an error (to avoid hanging) and notify the upper layer.
        for request in pending.removeAll() {
            request.resume(throwing: CompanionError.notConnected)
        }
        onDisconnect?()
    }
}
