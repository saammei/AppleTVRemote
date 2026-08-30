// Connection-layer abstraction: upper layers (protocol layer / pairing flow) do not care about
// the concrete transport (TCP / test mock).
// Corresponds to the CompanionConnection interface in pyatv's pyatv/protocols/companion/connection.py.
//
// The concrete TCP implementation (NWConnection) is wired up in Phase 3; this abstraction lets the
// pairing flow be tested end-to-end without a network.

import Foundation

public protocol CompanionConnectionListener: AnyObject {
    /// Received one frame. The payload has already been decrypted by the connection layer (if encryption is enabled).
    func connection(_ connection: CompanionConnection, didReceive frameType: FrameType, payload: Data)
    /// The connection has closed (explicit close, or remote disconnect/error). May be called multiple times; implementations must be idempotent.
    func connectionDidClose(_ connection: CompanionConnection)
}

public protocol CompanionConnection: AnyObject {
    var isConnected: Bool { get }
    var listener: CompanionConnectionListener? { get set }

    /// Establishes the connection (asynchronous; send/receive work once complete).
    func connect() async throws

    /// Closes the connection.
    func close()

    /// Sends a frame. Framing/encryption of the body is handled by the connection layer.
    func send(_ frameType: FrameType, payload: Data) throws

    /// Enables connection-layer encryption (two independent keys for output/input, each with its own counter).
    func enableEncryption(outputKey: Data, inputKey: Data)
}

public enum CompanionError: Error {
    case notConnected
    case timeout
    case invalidResponse
    case protocolError(String)
    case authenticationFailed(String)
}

extension CompanionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Device is not connected"
        case .timeout: return "Device response timed out"
        case .invalidResponse: return "The device returned an unparseable response"
        case .protocolError(let text): return "The device returned an error: \(text)"
        case .authenticationFailed(let text): return "Authentication failed: \(text)"
        }
    }
}
