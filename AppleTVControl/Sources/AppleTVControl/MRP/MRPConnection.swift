// MRP connection layer: abstract interface + TCP transport (NWConnection) + 8-byte nonce encryption.
// Corresponds to pyatv's pyatv/protocols/mrp/connection.py.
//
// Frame format: varint length prefix (LEB128) + protobuf-serialized message
// (ciphertext + 16-byte tag once encrypted).
// Encryption uses ChaCha20-Poly1305 with a 12-byte nonce = 4 zero bytes + 8-byte little-endian counter
// (corresponds to pyatv's Chacha20Cipher8byteNonce, different from Companion's 12-byte counter nonce).

import Foundation
import Network
import os

public protocol MRPConnectionListener: AnyObject {
    /// Received one complete message (already decrypted). data is the protobuf-serialized bytes.
    func connection(_ connection: MRPConnection, didReceive data: Data)
    /// The connection has closed (explicit close, or remote disconnect/error). May be called multiple times; implementations must be idempotent.
    func connectionDidClose(_ connection: MRPConnection)
}

public protocol MRPConnection: AnyObject {
    var isConnected: Bool { get }
    var listener: MRPConnectionListener? { get set }

    func connect() async throws
    func close()

    /// Sends a message (framing and encryption are handled by the connection layer).
    func send(_ data: Data) throws

    /// Enables connection-layer encryption (two independent keys for output/input, each with its own counter).
    func enableEncryption(outputKey: Data, inputKey: Data)
}

/// MRP connection-layer encryption: out/in use two independently incrementing 12-byte nonces (4 zero bytes + 8-byte little-endian counter).
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

/// MRP TCP transport implementation, based on Network.framework's NWConnection.
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
    /// Protects state / connectContinuation / didNotifyClose (accessed across threads).
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

    // MARK: - Lifecycle

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

    /// Notifies the listener that the connection closed (idempotent, notified only once).
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

    // MARK: - Sending

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

    // MARK: - Receiving

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

    /// Extracts as many complete messages as possible from the buffer and hands them to the listener after decryption.
    private func parseMessages() {
        while true {
            guard let (length, remaining) = Variant.decode(buffer) else { return }
            guard remaining.count >= length else { return }  // complete message not yet received
            var payload = Data(remaining.prefix(length))
            buffer = Data(remaining.dropFirst(length))

            if let cipher, !payload.isEmpty {
                do {
                    payload = try cipher.decrypt(payload)
                } catch {
                    // AEAD authentication failed: the nonce has already advanced; close the
                    // connection to avoid getting permanently out of sync.
                    close()
                    return
                }
            }
            listener?.connection(self, didReceive: payload)
        }
    }
}
