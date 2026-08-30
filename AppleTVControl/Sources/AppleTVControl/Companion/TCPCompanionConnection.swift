// TCP transport implementation for the Companion connection layer, based on Network.framework's NWConnection.
// Corresponds to the asyncio implementation in pyatv's pyatv/protocols/companion/connection.py.
//
// Responsibilities:
//   - Establish/close the TCP connection (NWConnection)
//   - Buffer the byte stream and split it into frames (CompanionFrame)
//   - Once encryption is enabled, decrypt inbound frames and encrypt outbound frames
//     (CompanionCipher, 12-byte counter nonce)
//   - Call complete frames back to the listener (i.e. CompanionProtocol)

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
    private let logger = Logger(subsystem: "com.meishaoming.AppleTVRemote", category: "companion.tcp")

    private var connection: NWConnection?
    /// Protects state / connectContinuation / didNotifyClose (accessed across threads).
    private var stateLock = os_unfair_lock()
    private var state: NWConnection.State = .setup
    private var cipher: CompanionCipher?
    private var buffer = Data()
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var connectTimeoutWorkItem: DispatchWorkItem?
    private var didNotifyClose = false

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    deinit {
        connection?.cancel()
    }

    // MARK: - Lifecycle

    /// Connection entry point satisfying the CompanionConnection protocol (default 10-second timeout).
    public func connect() async throws {
        try await connect(timeout: 10)
    }

    public func connect(timeout: TimeInterval) async throws {
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

            // Timeout fallback: for unreachable hosts (e.g. an Apple TV in standby), NWConnection
            // stays in .waiting without reporting an error, so we must time out ourselves,
            // otherwise the caller hangs forever.
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let pending = self.consumeConnectContinuation().0
                if let pending {
                    self.connection?.cancel()
                    pending.resume(throwing: CompanionError.timeout)
                }
            }
            connectTimeoutWorkItem = workItem
            queue.asyncAfter(deadline: .now() + timeout, execute: workItem)
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
        os_unfair_lock_unlock(&stateLock)

        switch newState {
        case .ready:
            let (continuation, timeoutItem) = consumeConnectContinuation()
            timeoutItem?.cancel()
            continuation?.resume(returning: ())
            startReceive()
        case .failed(let error):
            let (continuation, timeoutItem) = consumeConnectContinuation()
            timeoutItem?.cancel()
            continuation?.resume(throwing: error)
            notifyClose()
        case .cancelled:
            // If cancelled via the timeout path, connectContinuation has already been consumed,
            // so it will not be resumed again here.
            let (continuation, timeoutItem) = consumeConnectContinuation()
            timeoutItem?.cancel()
            continuation?.resume(throwing: CompanionError.notConnected)
            notifyClose()
        case .setup, .preparing, .waiting:
            // Intermediate states do not consume the continuation: .waiting is left to the timeout fallback.
            break
        @unknown default:
            break
        }
    }

    /// Takes (and clears) the pending-connect continuation and timeout task. Only a terminal state
    /// or the timeout task consumes them; whoever comes first wins, later callers get nil,
    /// guaranteeing exactly one resume.
    private func consumeConnectContinuation() -> (CheckedContinuation<Void, Error>?, DispatchWorkItem?) {
        os_unfair_lock_lock(&stateLock)
        let continuation = connectContinuation
        connectContinuation = nil
        let timeoutItem = connectTimeoutWorkItem
        connectTimeoutWorkItem = nil
        os_unfair_lock_unlock(&stateLock)
        return (continuation, timeoutItem)
    }

    // MARK: - Sending

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

    // MARK: - Receiving

    private func startReceive() {
        receiveNext()
    }

    private func receiveNext() {
        guard let connection, state == .ready else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            // receive's completion is called back on the queue given to start(queue:).
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

    /// Extracts as many complete frames as possible from the buffer and hands them to the listener after decryption.
    private func parseFrames() {
        while buffer.count >= CompanionFrame.headerLength {
            let header = Data(buffer.prefix(CompanionFrame.headerLength))
            let bufLen = buffer.count
            let headHex = (buffer.prefix(8) as NSData).description
            logger.debug("parseFrames buffer=\(bufLen, privacy: .public) header=\(headHex, privacy: .public)")
            guard let frame = CompanionFrame.decode(from: buffer) else { return }

            var payload = frame.payload
            buffer.removeFirst(frame.consumed)

            if let cipher, !payload.isEmpty {
                do {
                    payload = try cipher.decrypt(payload, aad: header)
                } catch {
                    // AEAD authentication failed (tampering / wrong key / replay): the nonce has already
                    // advanced, the connection is unrecoverable, so it must be closed.
                    close()
                    return
                }
            }
            listener?.connection(self, didReceive: frame.frameType, payload: payload)
        }
    }
}
