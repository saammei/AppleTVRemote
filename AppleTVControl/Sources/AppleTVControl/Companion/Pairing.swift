// Companion pairing flow: Pair-Setup (first-time pairing) and Pair-Verify (credential recovery).
// Corresponds to pyatv's pyatv/protocols/companion/auth.py.
//
// Both orchestrate message flows on top of SRPAuthHandler, with OPACK message structure:
//   Pair-Setup: {"_pd": <TLV bytes>, "_pwTy": 1}
//   Pair-Verify: {"_pd": <TLV bytes>, "_auTy": 4}

import Foundation

enum PairingKeys {
    static let pairingData = "_pd"
    static let pairingType = "_pwTy"
    static let authType = "_auTy"
}

/// Extracts the _pd bytes from a pairing message and decodes TLV8; throws if the device reported an error.
func pairingTLV(from message: [String: Any]) throws -> [UInt8: Data] {
    guard let pd = message[PairingKeys.pairingData] as? Data else {
        throw CompanionError.protocolError("Pairing message is missing the _pd field")
    }
    let tlv = TLV8.decode(pd)
    if let err = tlv[TLV8Tag.error.rawValue] {
        let text = String(data: err, encoding: .utf8) ?? "<binary>"
        throw CompanionError.authenticationFailed("Device returned an error: \(text)")
    }
    return tlv
}

/// First-time pairing: SRP-6a exchange and long-term credential exchange.
public final class CompanionPairSetupProcedure {
    private let protocolLayer: CompanionProtocol
    private let srp: SRPAuthHandler
    private var atvSalt: Data?
    private var atvPubKey: Data?

    public init(_ protocolLayer: CompanionProtocol, _ srp: SRPAuthHandler) {
        self.protocolLayer = protocolLayer
        self.srp = srp
    }

    /// Initiates pairing (M1/M2): generates keys and obtains the device's salt and public key.
    /// Fixed seeds (32 bytes each) can be passed in for deterministic testing; nil means random generation.
    public func startPairing(
        authPrivateSeed: Data? = nil, verifyPrivateSeed: Data? = nil
    ) async throws {
        try srp.initialize(
            authPrivateSeed: authPrivateSeed, verifyPrivateSeed: verifyPrivateSeed)

        let resp = try await protocolLayer.exchangeAuth(
            .psStart,
            [PairingKeys.pairingData: TLV8.encode([
                (TLV8Tag.method.rawValue, Data([0x00])),
                (TLV8Tag.seqNo.rawValue, Data([0x01])),
            ]),
            PairingKeys.pairingType: 1])

        let tlv = try pairingTLV(from: resp)
        atvSalt = tlv[TLV8Tag.salt.rawValue]
        atvPubKey = tlv[TLV8Tag.publicKey.rawValue]
    }

    /// Completes pairing (M3-M6) and returns the long-term credentials.
    public func finishPairing(pin: String, displayName: String? = nil) async throws -> HapCredentials {
        guard let atvPubKey, let atvSalt else {
            throw CompanionError.notConnected
        }

        srp.step1(pin: pin)
        let (pubKey, proof) = try srp.step2(atvPubKey: atvPubKey, atvSalt: atvSalt)

        let resp3 = try await protocolLayer.exchangeAuth(
            .psNext,
            [PairingKeys.pairingData: TLV8.encode([
                (TLV8Tag.seqNo.rawValue, Data([0x03])),
                (TLV8Tag.publicKey.rawValue, pubKey),
                (TLV8Tag.proof.rawValue, proof),
            ]),
            PairingKeys.pairingType: 1])

        _ = try pairingTLV(from: resp3)  // the device's M4 carries proof; pyatv does not verify it (matching upstream).

        let encryptedData = try srp.step3(name: displayName)
        let resp5 = try await protocolLayer.exchangeAuth(
            .psNext,
            [PairingKeys.pairingData: TLV8.encode([
                (TLV8Tag.seqNo.rawValue, Data([0x05])),
                (TLV8Tag.encryptedData.rawValue, encryptedData),
            ]),
            PairingKeys.pairingType: 1])

        let tlv6 = try pairingTLV(from: resp5)
        guard let deviceEncrypted = tlv6[TLV8Tag.encryptedData.rawValue] else {
            throw CompanionError.invalidResponse
        }
        return try srp.step4(encryptedData: deviceEncrypted)
    }
}

/// Credential recovery: Curve25519 + Ed25519 verification and derivation of new encryption keys.
public final class CompanionPairVerifyProcedure {
    private let protocolLayer: CompanionProtocol
    private let srp: SRPAuthHandler
    private let credentials: HapCredentials

    public init(_ protocolLayer: CompanionProtocol, _ srp: SRPAuthHandler, _ credentials: HapCredentials) {
        self.protocolLayer = protocolLayer
        self.srp = srp
        self.credentials = credentials
    }

    /// Verifies the device with the credentials (M1-M4).
    @discardableResult
    public func verifyCredentials() async throws -> Bool {
        let (_, publicKey) = try srp.initialize()

        let resp = try await protocolLayer.exchangeAuth(
            .pvStart,
            [PairingKeys.pairingData: TLV8.encode([
                (TLV8Tag.seqNo.rawValue, Data([0x01])),
                (TLV8Tag.publicKey.rawValue, publicKey),
            ]),
            PairingKeys.authType: 4])

        let tlv = try pairingTLV(from: resp)
        guard let serverPubKey = tlv[TLV8Tag.publicKey.rawValue],
              let encrypted = tlv[TLV8Tag.encryptedData.rawValue] else {
            throw CompanionError.invalidResponse
        }

        let encryptedData = try srp.verify1(
            credentials: credentials, sessionPubKey: serverPubKey, encrypted: encrypted)

        _ = try await protocolLayer.exchangeAuth(
            .pvNext,
            [PairingKeys.pairingData: TLV8.encode([
                (TLV8Tag.seqNo.rawValue, Data([0x03])),
                (TLV8Tag.encryptedData.rawValue, encryptedData),
            ])])

        return true
    }

    /// Derives the output/input encryption keys.
    public func encryptionKeys(
        salt: String, outputInfo: String, inputInfo: String
    ) throws -> (outputKey: Data, inputKey: Data) {
        try srp.verify2(salt: salt, outputInfo: outputInfo, inputInfo: inputInfo)
    }
}
