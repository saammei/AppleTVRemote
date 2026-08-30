// Companion protocol layer: implements request/response dispatch on top of the connection layer
// (by XID or frame type).
// Corresponds to pyatv's pyatv/protocols/companion/protocol.py.
//
// - exchangeAuth: authentication frames (PS_*/PV_*), responses dispatched by frame type (pairing is serial, no XID).
// - exchangeOpack: regular OPACK messages, responses dispatched by _x (XID).
// - Events (_t == 1) are reported through the delegate, used for Phase 3 status/apps pushes.

import Foundation
import os

public protocol CompanionProtocolDelegate: AnyObject {
    func companionProtocol(_ protocol: CompanionProtocol, didReceiveEvent name: String, content: [String: Any])
}

/// Message type (the _t field of OPACK).
public enum CompanionMessageType: Int64 {
    case event = 1
    case request = 2
    case response = 3
}

/// Constants used to derive the encryption keys (pyatv protocol.py).
enum CompanionKeyInfo {
    static let salt = ""
    static let outputInfo = "ClientEncrypt-main"
    static let inputInfo = "ServerEncrypt-main"
}

public final class CompanionProtocol: CompanionConnectionListener {
    public let connection: CompanionConnection
    public let srp: SRPAuthHandler
    public weak var delegate: CompanionProtocolDelegate?

    /// Request dispatch key: auth frames by frame type, regular OPACK by XID.
    private enum RequestId: Hashable {
        case auth(FrameType)
        case opack(Int)
    }

    /// A single pending request. The store's atomic remove guarantees the continuation is resumed exactly once.
    private final class PendingRequest: @unchecked Sendable {
        private let continuation: CheckedContinuation<[String: Any], Error>
        init(_ continuation: CheckedContinuation<[String: Any], Error>) {
            self.continuation = continuation
        }
        func resume(returning value: [String: Any]) { continuation.resume(returning: value) }
        func resume(throwing error: Error) { continuation.resume(throwing: error) }
    }

    /// Pending-request store, protected by os_unfair_lock (critical sections are very short, no recursion).
    private final class PendingStore: @unchecked Sendable {
        private var pending: [RequestId: PendingRequest] = [:]
        private var lock = os_unfair_lock()

        func set(_ id: RequestId, _ request: PendingRequest) {
            os_unfair_lock_lock(&lock)
            pending[id] = request
            os_unfair_lock_unlock(&lock)
        }

        func remove(_ id: RequestId) -> PendingRequest? {
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

    private var xid: Int
    private var xidLock = os_unfair_lock()
    private let pending = PendingStore()
    private var isStarted = false

    public init(connection: CompanionConnection, srp: SRPAuthHandler) {
        self.connection = connection
        self.srp = srp
        self.xid = Int.random(in: 0..<0x10000)
        connection.listener = self
    }

    // MARK: - Lifecycle

    /// Connects to the device; if credentials are present, runs Pair-Verify and enables connection-layer encryption.
    public func start(credentials: HapCredentials?) async throws {
        guard !isStarted else { return }
        isStarted = true
        try await connection.connect()
        guard let credentials else { return }

        let verifier = CompanionPairVerifyProcedure(self, srp, credentials)
        try await verifier.verifyCredentials()
        let keys = try verifier.encryptionKeys(
            salt: CompanionKeyInfo.salt,
            outputInfo: CompanionKeyInfo.outputInfo,
            inputInfo: CompanionKeyInfo.inputInfo)
        connection.enableEncryption(outputKey: keys.outputKey, inputKey: keys.inputKey)
    }

    public func stop() {
        for request in pending.removeAll() {
            request.resume(throwing: CompanionError.notConnected)
        }
        connection.close()
    }

    // MARK: - Request/response

    /// Authentication frame exchange. Responses to *_Start frames arrive as *_Next, so dispatch by *_Next.
    public func exchangeAuth(_ frameType: FrameType, _ data: [String: Any], timeout: TimeInterval = 5) async throws -> [String: Any] {
        let identifier: FrameType
        switch frameType {
        case .psStart: identifier = .psNext
        case .pvStart: identifier = .pvNext
        default: identifier = frameType
        }
        return try await exchangeGeneric(frameType, data, identifier: .auth(identifier), timeout: timeout)
    }

    /// Regular OPACK message exchange (with XID).
    public func exchangeOpack(_ frameType: FrameType, _ data: [String: Any], timeout: TimeInterval = 5) async throws -> [String: Any] {
        var data = data
        let currentXid = nextXid()
        data["_x"] = currentXid
        return try await exchangeGeneric(frameType, data, identifier: .opack(currentXid), timeout: timeout)
    }

    /// Sends an OPACK message (no response awaited). Fills in _x automatically.
    public func sendOpack(_ frameType: FrameType, _ data: [String: Any]) throws {
        var data = data
        if data["_x"] == nil {
            data["_x"] = nextXid()
        }
        try connection.send(frameType, payload: OPACK.pack(data))
    }

    private func nextXid() -> Int {
        os_unfair_lock_lock(&xidLock)
        let current = xid
        xid += 1
        os_unfair_lock_unlock(&xidLock)
        return current
    }

    private func exchangeGeneric(
        _ frameType: FrameType, _ data: [String: Any], identifier: RequestId, timeout: TimeInterval
    ) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            let request = PendingRequest(continuation)
            // Register before sending, so the placeholder is ready before the response arrives.
            pending.set(identifier, request)

            do {
                try connection.send(frameType, payload: OPACK.pack(data))
            } catch {
                pending.remove(identifier)?.resume(throwing: error)
                return
            }

            // Timeout fallback: if no response arrives in time, remove and report a timeout.
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                pending.remove(identifier)?.resume(throwing: CompanionError.timeout)
            }
        }
    }

    // MARK: - CompanionConnectionListener

    public func connection(_ connection: CompanionConnection, didReceive frameType: FrameType, payload: Data) {
        guard isAuthFrame(frameType) || isOpackFrame(frameType) else { return }
        guard let (value, _) = OPACK.unpack(payload), let dict = value as? [String: Any] else { return }

        if isAuthFrame(frameType) {
            resume(pending.remove(.auth(frameType)), with: dict)
        } else {
            handleOpack(dict)
        }
    }

    public func connectionDidClose(_ connection: CompanionConnection) {
        // On disconnect: fail all pending requests with an error (to avoid hanging) and notify the upper layer.
        for request in pending.removeAll() {
            request.resume(throwing: CompanionError.notConnected)
        }
        onDisconnect?()
    }

    /// Resumes a pending request. A response carrying the `_em` field means the device reported an error (pyatv throws ProtocolError).
    private func resume(_ request: PendingRequest?, with dict: [String: Any]) {
        guard let request else { return }
        if let errorMessage = dict["_em"] {
            let text = (errorMessage as? String) ?? String(describing: errorMessage)
            request.resume(throwing: CompanionError.protocolError(text))
        } else {
            request.resume(returning: dict)
        }
    }

    private func handleOpack(_ data: [String: Any]) {
        guard let type = data["_t"] as? Int64,
              let messageType = CompanionMessageType(rawValue: type) else { return }

        switch messageType {
        case .event:
            // Events: report to the delegate.
            if let name = data["_i"] as? String, let content = data["_c"] as? [String: Any] {
                delegate?.companionProtocol(self, didReceiveEvent: name, content: content)
            }
        case .response:
            guard let responseXid = data["_x"] as? Int64 else { return }
            resume(pending.remove(.opack(Int(responseXid))), with: data)
        case .request:
            // Requests initiated by the device (e.g. key queries); handled in Phase 3.
            break
        }
    }

    private func isAuthFrame(_ frameType: FrameType) -> Bool {
        switch frameType {
        case .psStart, .psNext, .pvStart, .pvNext: return true
        default: return false
        }
    }

    private func isOpackFrame(_ frameType: FrameType) -> Bool {
        switch frameType {
        case .uOpack, .eOpack, .pOpack: return true
        default: return false
        }
    }
}
