// Companion 协议层:在连接层之上实现请求/响应的配对(按 XID 或帧类型派发)。
// 对应 pyatv 的 pyatv/protocols/companion/protocol.py。
//
// - exchangeAuth:认证帧(PS_*/PV_*),响应按帧类型派发(配对是串行的,无 XID)。
// - exchangeOpack:普通 OPACK 消息,响应按 _x(XID)派发。
// - 事件(_t == 1)经 delegate 上报,用于 Phase 3 的状态/apps 推送。

import Foundation
import os

public protocol CompanionProtocolDelegate: AnyObject {
    func companionProtocol(_ protocol: CompanionProtocol, didReceiveEvent name: String, content: [String: Any])
}

/// 消息类型(OPACK 的 _t 字段)。
public enum CompanionMessageType: Int64 {
    case event = 1
    case request = 2
    case response = 3
}

/// 派生加密密钥所用的常量(pyatv protocol.py)。
enum CompanionKeyInfo {
    static let salt = ""
    static let outputInfo = "ClientEncrypt-main"
    static let inputInfo = "ServerEncrypt-main"
}

public final class CompanionProtocol: CompanionConnectionListener {
    public let connection: CompanionConnection
    public let srp: SRPAuthHandler
    public weak var delegate: CompanionProtocolDelegate?

    /// 请求派发键:认证帧按帧类型,普通 OPACK 按 XID。
    private enum RequestId: Hashable {
        case auth(FrameType)
        case opack(Int)
    }

    /// 单个待响应请求。由 store 的原子 remove 保证 continuation 恰好 resume 一次。
    private final class PendingRequest: @unchecked Sendable {
        private let continuation: CheckedContinuation<[String: Any], Error>
        init(_ continuation: CheckedContinuation<[String: Any], Error>) {
            self.continuation = continuation
        }
        func resume(returning value: [String: Any]) { continuation.resume(returning: value) }
        func resume(throwing error: Error) { continuation.resume(throwing: error) }
    }

    /// 待响应请求存储。os_unfair_lock 保护(临界区极短,无递归)。
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

    private var xid: Int
    private let pending = PendingStore()
    private var isStarted = false

    public init(connection: CompanionConnection, srp: SRPAuthHandler) {
        self.connection = connection
        self.srp = srp
        self.xid = Int.random(in: 0..<0x10000)
        connection.listener = self
    }

    // MARK: - 生命周期

    /// 连接设备;若带凭证则执行 Pair-Verify 并启用连接层加密。
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

    // MARK: - 请求/响应

    /// 认证帧交换。*_Start 帧的响应以 *_Next 到达,故按 *_Next 派发。
    public func exchangeAuth(_ frameType: FrameType, _ data: [String: Any], timeout: TimeInterval = 5) async throws -> [String: Any] {
        let identifier: FrameType
        switch frameType {
        case .psStart: identifier = .psNext
        case .pvStart: identifier = .pvNext
        default: identifier = frameType
        }
        return try await exchangeGeneric(frameType, data, identifier: .auth(identifier), timeout: timeout)
    }

    /// 普通 OPACK 消息交换(带 XID)。
    public func exchangeOpack(_ frameType: FrameType, _ data: [String: Any], timeout: TimeInterval = 5) async throws -> [String: Any] {
        var data = data
        let currentXid = nextXid()
        data["_x"] = currentXid
        return try await exchangeGeneric(frameType, data, identifier: .opack(currentXid), timeout: timeout)
    }

    /// 发送 OPACK 消息(不等待响应)。自动补齐 _x。
    public func sendOpack(_ frameType: FrameType, _ data: [String: Any]) throws {
        var data = data
        if data["_x"] == nil {
            data["_x"] = nextXid()
        }
        try connection.send(frameType, payload: OPACK.pack(data))
    }

    private func nextXid() -> Int {
        let current = xid
        xid += 1
        return current
    }

    private func exchangeGeneric(
        _ frameType: FrameType, _ data: [String: Any], identifier: RequestId, timeout: TimeInterval
    ) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            let request = PendingRequest(continuation)
            // 先注册再发送,确保响应到达前占位已就绪。
            pending.set(identifier, request)

            do {
                try connection.send(frameType, payload: OPACK.pack(data))
            } catch {
                pending.remove(identifier)?.resume(throwing: error)
                return
            }

            // 超时兜底:到点未响应则移除并报超时。
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

    /// 恢复一个待响应请求。响应带 `_em` 字段表示设备报错(pyatv 抛 ProtocolError)。
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
            // 事件:上报 delegate。
            if let name = data["_i"] as? String, let content = data["_c"] as? [String: Any] {
                delegate?.companionProtocol(self, didReceiveEvent: name, content: content)
            }
        case .response:
            guard let responseXid = data["_x"] as? Int64 else { return }
            resume(pending.remove(.opack(Int(responseXid))), with: data)
        case .request:
            // 设备发起的请求(如按键查询),Phase 3 再处理。
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
