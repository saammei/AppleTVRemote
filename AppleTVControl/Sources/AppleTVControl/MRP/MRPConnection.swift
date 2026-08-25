// MRP 连接层:抽象接口 + TCP 传输(NWConnection)+ 8 字节 nonce 加密。
// 对应 pyatv 的 pyatv/protocols/mrp/connection.py。
//
// 帧格式:varint 长度前缀(LEB128)+ protobuf 序列化消息(加密后为 ciphertext+16 字节 tag)。
// 加密用 ChaCha20-Poly1305,nonce 为 12 字节 = 4 零字节 + 8 字节小端计数器
// (对应 pyatv 的 Chacha20Cipher8byteNonce,与 Companion 的 12 字节计数器 nonce 不同)。

import Foundation
import Network
import os

public protocol MRPConnectionListener: AnyObject {
    /// 收到一条完整消息(已解密)。data 为 protobuf 序列化字节。
    func connection(_ connection: MRPConnection, didReceive data: Data)
    /// 连接已断开(主动 close 或远端断开/错误)。可能被多次调用,实现需幂等。
    func connectionDidClose(_ connection: MRPConnection)
}

public protocol MRPConnection: AnyObject {
    var isConnected: Bool { get }
    var listener: MRPConnectionListener? { get set }

    func connect() async throws
    func close()

    /// 发送一条消息(帧打包与加密由连接层负责)。
    func send(_ data: Data) throws

    /// 启用连接层加密(输出/输入两把独立密钥,各带独立计数器)。
    func enableEncryption(outputKey: Data, inputKey: Data)
}

/// MRP 连接层加密:out/in 两个独立递增的 12 字节 nonce(4 零字节 + 8 字节小端计数器)。
public final class MRPCipher {
    private let outKey: Data
    private let inKey: Data
    private var outCounter: UInt64 = 0
    private var inCounter: UInt64 = 0
    private var outLock = os_unfair_lock()
    private var inLock = os_unfair_lock()

    public init(outKey: Data, inKey: Data) {
        self.outKey = outKey
        self.inKey = inKey
    }

    public func encrypt(_ data: Data) throws -> Data {
        os_unfair_lock_lock(&outLock)
        let nonce = ChaCha20Poly1305.nonceCounter8(outCounter)
        outCounter += 1
        os_unfair_lock_unlock(&outLock)
        return try ChaCha20Poly1305.seal(data, key: outKey, nonce: nonce, aad: Data())
    }

    public func decrypt(_ data: Data) throws -> Data {
        os_unfair_lock_lock(&inLock)
        let nonce = ChaCha20Poly1305.nonceCounter8(inCounter)
        inCounter += 1
        os_unfair_lock_unlock(&inLock)
        return try ChaCha20Poly1305.open(data, key: inKey, nonce: nonce, aad: Data())
    }
}

/// MRP 的 TCP 传输实现,基于 Network.framework 的 NWConnection。
public final class MRPTCPConnection: MRPConnection {
    public var isConnected: Bool {
        os_unfair_lock_lock(&stateLock)
        defer { os_unfair_lock_unlock(&stateLock) }
        return state == .ready
    }
    public weak var listener: MRPConnectionListener?

    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "atv.mrp.tcp")

    private var connection: NWConnection?
    /// 保护 state / connectContinuation / didNotifyClose(跨线程访问)。
    private var stateLock = os_unfair_lock()
    private var state: NWConnection.State = .setup
    private var cipher: MRPCipher?
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

    public func send(_ data: Data) throws {
        os_unfair_lock_lock(&stateLock)
        let ready = state == .ready
        os_unfair_lock_unlock(&stateLock)
        guard ready, let connection else {
            throw CompanionError.notConnected
        }
        var payload = data
        if let cipher, !data.isEmpty {
            payload = try cipher.encrypt(data)
        }
        let framed = Variant.encode(payload.count) + payload
        connection.send(content: framed, completion: .contentProcessed { _ in })
    }

    public func enableEncryption(outputKey: Data, inputKey: Data) {
        cipher = MRPCipher(outKey: outputKey, inKey: inputKey)
    }

    // MARK: - 接收

    private func startReceive() {
        receiveNext()
    }

    private func receiveNext() {
        guard let connection, state == .ready else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.parseMessages()
            }
            if error != nil || isComplete {
                self.close()
                return
            }
            self.receiveNext()
        }
    }

    /// 从缓冲里尽量多地拆出完整消息,解密后交给 listener。
    private func parseMessages() {
        while true {
            guard let (length, remaining) = Variant.decode(buffer) else { return }
            guard remaining.count >= length else { return }  // 整条消息未到齐
            var payload = Data(remaining.prefix(length))
            buffer = Data(remaining.dropFirst(length))

            if let cipher, !payload.isEmpty {
                do {
                    payload = try cipher.decrypt(payload)
                } catch {
                    // AEAD 认证失败:nonce 已超前,断开连接避免永久失步。
                    close()
                    return
                }
            }
            listener?.connection(self, didReceive: payload)
        }
    }
}
