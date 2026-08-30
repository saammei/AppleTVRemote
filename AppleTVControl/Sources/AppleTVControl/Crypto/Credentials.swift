// HAP pairing credentials. Corresponds to pyatv's HapCredentials.
// After pairing completes, these four values are used by subsequent Pair-Verify
// to re-establish an encrypted session.

import Foundation

public struct HapCredentials: Equatable {
    /// Apple TV's long-term public key (Ed25519, 32 bytes).
    public let ltpk: Data
    /// This device's (controller) long-term private key (Ed25519 seed, 32 bytes).
    public let ltsk: Data
    /// Apple TV's pairing identifier.
    public let atvId: Data
    /// This device's (controller) pairing identifier (client_id).
    public let clientId: Data

    public init(ltpk: Data, ltsk: Data, atvId: Data, clientId: Data) {
        self.ltpk = ltpk
        self.ltsk = ltsk
        self.atvId = atvId
        self.clientId = clientId
    }

    /// Serializes to "ltpk:ltsk:atv_id:client_id" (each field hex), matching pyatv's str.
    /// Used for persistence to a file or settings.
    public var detailString: String {
        [ltpk, ltsk, atvId, clientId].map { $0.hex }.joined(separator: ":")
    }

    /// Parses from a detailString.
    public static func parse(_ string: String) -> HapCredentials? {
        let parts = string.split(separator: ":").map(String.init)
        guard parts.count == 4,
              let ltpk = Data(hex: parts[0]),
              let ltsk = Data(hex: parts[1]),
              let atvId = Data(hex: parts[2]),
              let clientId = Data(hex: parts[3]) else { return nil }
        return HapCredentials(ltpk: ltpk, ltsk: ltsk, atvId: atvId, clientId: clientId)
    }
}
