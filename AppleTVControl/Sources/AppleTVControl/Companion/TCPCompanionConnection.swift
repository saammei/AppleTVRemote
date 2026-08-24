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
    public var isConnected: Bool { state == .ready }
    public weak var listener: CompanionConnectionListener?

    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "atv.companion.tcp")

    private var connection: NWConnection?
    private var state: NWConnection.State = .setup
    private var cipher: CompanionCipher?
    private var buffer = Data()
    private var connectContinuation: CheckedContinuation<Void, Error>?

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    deinit {
        connection?.cancel()
    }

    // MARK: - 生命周期

    public func connect() async throws {
        guard state != .ready else { return }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 49152
        )
        let conn = NWConnection(to: endpoint, using: .tcp)
        connection = conn
        state = .setup

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectContinuation = continuation
            conn.stateUpdateHandler = { [weak self] newState in
                self?.handleState(newState)
            }
            conn.start(queue: queue)
        }
    }

    public func close() {
        connection?.cancel()
        connection = nil
        state = .cancelled
    }

    private func handleState(_ newState: NWConnection.State) {
        state = newState
        switch newState {
        case .ready:
            connectContinuation?.resume(returning: ())
            connectContinuation = nil
            startReceive()
        case .failed(let error):
            connectContinuation?.resume(throwing: error)
            connectContinuation = nil
        case .cancelled:
            connectContinuation?.resume(throwing: CompanionError.notConnected)
            connectContinuation = nil
        case .setup, .preparing, .waiting:
            break
        @unknown default:
            break
        }
    }

    // MARK: - 发送

    public func send(_ frameType: FrameType, payload: Data) throws {
        guard let connection, state == .ready else {
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
                    // 解密失败(密钥错误 / 篡改):丢弃该帧,继续处理后续。
                    continue
                }
            }
            listener?.connection(self, didReceive: frame.frameType, payload: payload)
        }
    }
}
