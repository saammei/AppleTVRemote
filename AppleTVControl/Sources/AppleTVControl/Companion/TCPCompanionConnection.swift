// Companion 连接层的 TCP 传输实现,基于 Network.framework 的 NWConnection。
// 对应 pyatv 的 pyatv/protocols/companion/connection.py 的 asyncio 实现。
//
// 职责:
//   - 建立/关闭 TCP 连接(NWConnection)
//   - 字节流缓冲 → 拆帧(CompanionFrame)
//   - 启用加密后,对入帧解密、出帧加密(CompanionCipher,12 字节计数器 nonce)
//   - 把完整帧回调给 listener(即 CompanionProtocol)

import Foundation
import Network
import os

public final class TCPCompanionConnection: CompanionConnection {
    public var isConnected: Bool {
        os_unfair_lock_lock(&stateLock)
        defer { os_unfair_lock_unlock(&stateLock) }
        return state == .ready
    }
    public weak var listener: CompanionConnectionListener?

    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "atv.companion.tcp")

    private var connection: NWConnection?
    /// 保护 state / connectContinuation / didNotifyClose(跨线程访问)。
    private var stateLock = os_unfair_lock()
    private var state: NWConnection.State = .setup
    private var cipher: CompanionCipher?
    private var buffer = Data()
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var didNotifyClose = false

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    deinit {
        connection?.cancel()
    }

    // MARK: - 生命周期

    public func connect() async throws {
        os_unfair_lock_lock(&stateLock)
        let current = state
        os_unfair_lock_unlock(&stateLock)
        guard current != .ready else { return }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 49152
        )
        let conn = NWConnection(to: endpoint, using: .tcp)
        connection = conn
        os_unfair_lock_lock(&stateLock)
        state = .setup
        os_unfair_lock_unlock(&stateLock)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            os_unfair_lock_lock(&stateLock)
            connectContinuation = continuation
            os_unfair_lock_unlock(&stateLock)
            conn.stateUpdateHandler = { [weak self] newState in
                self?.handleState(newState)
            }
            conn.start(queue: queue)
        }
    }

    public func close() {
        connection?.cancel()
        connection = nil
        os_unfair_lock_lock(&stateLock)
        state = .cancelled
        os_unfair_lock_unlock(&stateLock)
        notifyClose()
    }

    /// 通知 listener 连接已断开(幂等,只通知一次)。
    private func notifyClose() {
        os_unfair_lock_lock(&stateLock)
        guard !didNotifyClose else {
            os_unfair_lock_unlock(&stateLock)
            return
        }
        didNotifyClose = true
        os_unfair_lock_unlock(&stateLock)
        listener?.connectionDidClose(self)
    }

    private func handleState(_ newState: NWConnection.State) {
        os_unfair_lock_lock(&stateLock)
        state = newState
        let continuation = connectContinuation
        connectContinuation = nil
        os_unfair_lock_unlock(&stateLock)

        switch newState {
        case .ready:
            continuation?.resume(returning: ())
            startReceive()
        case .failed(let error):
            continuation?.resume(throwing: error)
            notifyClose()
        case .cancelled:
            continuation?.resume(throwing: CompanionError.notConnected)
            notifyClose()
        case .setup, .preparing, .waiting:
            break
        @unknown default:
            break
        }
    }

    // MARK: - 发送

    public func send(_ frameType: FrameType, payload: Data) throws {
        os_unfair_lock_lock(&stateLock)
        let ready = state == .ready
        os_unfair_lock_unlock(&stateLock)
        guard ready, let connection else {
            throw CompanionError.notConnected
        }
        let data = try CompanionFrame.encode(frameType: frameType, payload: payload, cipher: cipher)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    public func enableEncryption(outputKey: Data, inputKey: Data) {
        cipher = CompanionCipher(outKey: outputKey, inKey: inputKey)
    }

    // MARK: - 接收

    private func startReceive() {
        receiveNext()
    }

    private func receiveNext() {
        guard let connection, state == .ready else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            // receive 的 completion 在 start(queue:) 指定的队列上回调。
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.parseFrames()
            }
            if error != nil || isComplete {
                self.close()
                return
            }
            self.receiveNext()
        }
    }

    /// 从缓冲里尽量多地拆出完整帧,解密后交给 listener。
    private func parseFrames() {
        while buffer.count >= CompanionFrame.headerLength {
            let header = Data(buffer.prefix(CompanionFrame.headerLength))
            guard let frame = CompanionFrame.decode(from: buffer) else { return }

            var payload = frame.payload
            buffer.removeFirst(frame.consumed)

            if let cipher, !payload.isEmpty {
                do {
                    payload = try cipher.decrypt(payload, aad: header)
                } catch {
                    // AEAD 认证失败(篡改/密钥错/重放):nonce 已超前,连接不可恢复,必须断开。
                    close()
                    return
                }
            }
            listener?.connection(self, didReceive: frame.frameType, payload: payload)
        }
    }
}
