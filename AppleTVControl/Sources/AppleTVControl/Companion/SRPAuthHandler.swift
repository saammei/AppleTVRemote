// SRP authentication handler: the cryptographic logic for pairing (Pair-Setup) and verification (Pair-Verify).
// Corresponds to SRPAuthHandler in pyatv's pyatv/auth/hap_srp.py.
//
// Pair-Setup establishes long-term credentials (Ed25519 signing key + SRP); Pair-Verify derives
// session keys from existing credentials (X25519 + HKDF). Both reuse this file's key generation
// and encryption/decryption.

import Foundation
import CryptoKit

public enum SRPError: Error, Equatable {
    case notInitialized
    case srpRejected
    case invalidResponse
    case authenticationFailed(String)
}

public final class SRPAuthHandler {
    /// Client pairing identifier (UUID string, 36 bytes). Used as the new client_id during Pair-Setup.
    public let pairingId: Data

    // Pair-Setup keys (Ed25519 signing)
    private var signingKey: Curve25519.Signing.PrivateKey?
    private var authPrivate: Data?
    private var authPublic: Data?

    // Pair-Verify keys (X25519)
    private var verifyPrivate: Curve25519.KeyAgreement.PrivateKey?
    private var publicBytes: Data?

    // Intermediate state
    private var pin: String?
    private var srpSessionKey: Data?   // SRP K (64 bytes)
    private var sharedSecret: Data?    // X25519 shared secret (32 bytes)
    private var sessionKey: Data?      // Pair-Setup encryption key (32 bytes)

    public init(pairingId: Data? = nil) {
        if let pairingId {
            self.pairingId = pairingId
        } else {
            // pyatv uses str(uuid.uuid4()), a 36-byte lowercase string.
            self.pairingId = Data(UUID().uuidString.lowercased().utf8)
        }
    }

    // MARK: - Key generation

    /// Generates the Ed25519 signing key + X25519 key. Returns (authPublic, publicBytes).
    /// Fixed seeds (32 bytes each) can be passed in for deterministic testing or credential recovery;
    /// nil means random generation.
    @discardableResult
    public func initialize(
        authPrivateSeed: Data? = nil,
        verifyPrivateSeed: Data? = nil
    ) throws -> (authPublic: Data, publicBytes: Data) {
        let signing: Curve25519.Signing.PrivateKey
        if let authPrivateSeed {
            signing = try Curve25519.Signing.PrivateKey(rawRepresentation: authPrivateSeed)
        } else {
            signing = Curve25519.Signing.PrivateKey()
        }
        let verifyPriv: Curve25519.KeyAgreement.PrivateKey
        if let verifyPrivateSeed {
            verifyPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: verifyPrivateSeed)
        } else {
            verifyPriv = Curve25519.KeyAgreement.PrivateKey()
        }

        let authPub = signing.publicKey.rawRepresentation
        let verifyPub = verifyPriv.publicKey.rawRepresentation
        signingKey = signing
        authPrivate = signing.rawRepresentation
        authPublic = authPub
        verifyPrivate = verifyPriv
        publicBytes = verifyPub
        return (authPub, verifyPub)
    }

    // MARK: - Pair-Setup (SRP)

    /// step1: records the PIN (the actual SRP computation happens in step2).
    public func step1(pin: String) {
        self.pin = pin
    }

    /// step2: computes the client public key A and proof M. Returns (A's minimal bytes, M).
    public func step2(atvPubKey: Data, atvSalt: Data) throws -> (pubKey: Data, proof: Data) {
        guard let authPrivate, let pin else { throw SRPError.notInitialized }
        guard let result = SRP6a.process(
            username: "Pair-Setup", password: pin,
            clientPrivateBytes: authPrivate,
            serverPublicBytes: atvPubKey, salt: atvSalt
        ) else {
            throw SRPError.srpRejected
        }
        srpSessionKey = result.sessionKey
        return (result.clientPublic, result.proof)
    }

    /// step3: builds and encrypts the controller info (identifier + public key + signature). Returns the ciphertext (PS-Msg05).
    public func step3(name: String? = nil) throws -> Data {
        guard let signingKey, let authPublic, let srpSessionKey else {
            throw SRPError.notInitialized
        }

        let iosDeviceX = HKDF.sha512(
            ikm: srpSessionKey,
            salt: Data("Pair-Setup-Controller-Sign-Salt".utf8),
            info: Data("Pair-Setup-Controller-Sign-Info".utf8))
        let sessionKey = HKDF.sha512(
            ikm: srpSessionKey,
            salt: Data("Pair-Setup-Encrypt-Salt".utf8),
            info: Data("Pair-Setup-Encrypt-Info".utf8))
        self.sessionKey = sessionKey

        var deviceInfo = Data()
        deviceInfo.append(iosDeviceX)
        deviceInfo.append(pairingId)
        deviceInfo.append(authPublic)
        let deviceSignature = try signingKey.signature(for: deviceInfo)

        var entries: [(UInt8, Data)] = [
            (TLV8Tag.identifier.rawValue, pairingId),
            (TLV8Tag.publicKey.rawValue, authPublic),
            (TLV8Tag.signature.rawValue, deviceSignature),
        ]
        // pyatv: tlv[Name] = opack.pack({"name": name})
        if let name {
            entries.append((TLV8Tag.name.rawValue, OPACK.pack(["name": name])))
        }

        let tlv = TLV8.encode(entries)
        let nonce = ChaCha20Poly1305.nonce8("PS-Msg05")
        return try ChaCha20Poly1305.seal(tlv, key: sessionKey, nonce: nonce, aad: Data())
    }

    /// step4: decrypts the device info (PS-Msg06) and obtains the long-term credentials.
    public func step4(encryptedData: Data) throws -> HapCredentials {
        guard let sessionKey, let authPrivate else { throw SRPError.notInitialized }

        let nonce = ChaCha20Poly1305.nonce8("PS-Msg06")
        let decrypted = try ChaCha20Poly1305.open(encryptedData, key: sessionKey, nonce: nonce, aad: Data())
        let tlv = TLV8.decode(decrypted)

        guard let atvIdentifier = tlv[TLV8Tag.identifier.rawValue],
              let atvPubKey = tlv[TLV8Tag.publicKey.rawValue] else {
            throw SRPError.invalidResponse
        }
        // pyatv does not verify the device signature here (TODO); keep the same behavior.

        return HapCredentials(
            ltpk: atvPubKey, ltsk: authPrivate,
            atvId: atvIdentifier, clientId: pairingId)
    }

    // MARK: - Pair-Verify

    /// verify1: verifies the device with the credentials and signs the controller info. Returns the ciphertext (PV-Msg03).
    public func verify1(
        credentials: HapCredentials, sessionPubKey: Data, encrypted: Data
    ) throws -> Data {
        guard let verifyPrivate, let publicBytes else { throw SRPError.notInitialized }

        let serverPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: sessionPubKey)
        let shared = try verifyPrivate.sharedSecretFromKeyAgreement(with: serverPublic)
        let sharedBytes = shared.withUnsafeBytes { Data($0) }
        sharedSecret = sharedBytes

        let sessionKey = HKDF.sha512(
            ikm: sharedBytes,
            salt: Data("Pair-Verify-Encrypt-Salt".utf8),
            info: Data("Pair-Verify-Encrypt-Info".utf8))

        let nonce2 = ChaCha20Poly1305.nonce8("PV-Msg02")
        let decrypted = try ChaCha20Poly1305.open(encrypted, key: sessionKey, nonce: nonce2, aad: Data())
        let tlv = TLV8.decode(decrypted)

        guard let identifier = tlv[TLV8Tag.identifier.rawValue],
              let signature = tlv[TLV8Tag.signature.rawValue] else {
            throw SRPError.invalidResponse
        }

        guard identifier == credentials.atvId else {
            throw SRPError.authenticationFailed("incorrect device response")
        }

        // Verify the device signature: info = sessionPubKey + identifier + publicBytes
        var info = Data()
        info.append(sessionPubKey)
        info.append(identifier)
        info.append(publicBytes)
        let ltpk = try Curve25519.Signing.PublicKey(rawRepresentation: credentials.ltpk)
        guard ltpk.isValidSignature(signature, for: info) else {
            throw SRPError.authenticationFailed("signature error")
        }

        // Sign the controller info: device_info = publicBytes + clientId + sessionPubKey
        var deviceInfo = Data()
        deviceInfo.append(publicBytes)
        deviceInfo.append(credentials.clientId)
        deviceInfo.append(sessionPubKey)
        let ltsk = try Curve25519.Signing.PrivateKey(rawRepresentation: credentials.ltsk)
        let deviceSignature = try ltsk.signature(for: deviceInfo)

        let responseTLV = TLV8.encode([
            (TLV8Tag.identifier.rawValue, credentials.clientId),
            (TLV8Tag.signature.rawValue, deviceSignature),
        ])
        let nonce3 = ChaCha20Poly1305.nonce8("PV-Msg03")
        return try ChaCha20Poly1305.seal(responseTLV, key: sessionKey, nonce: nonce3, aad: Data())
    }

    /// verify2: derives the output/input encryption keys.
    public func verify2(salt: String, outputInfo: String, inputInfo: String) throws -> (outputKey: Data, inputKey: Data) {
        guard let sharedSecret else { throw SRPError.notInitialized }
        let outputKey = HKDF.sha512(
            ikm: sharedSecret, salt: Data(salt.utf8), info: Data(outputInfo.utf8))
        let inputKey = HKDF.sha512(
            ikm: sharedSecret, salt: Data(salt.utf8), info: Data(inputInfo.utf8))
        return (outputKey, inputKey)
    }
}
