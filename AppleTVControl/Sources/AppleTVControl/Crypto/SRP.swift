// SRP-6a client implementation (RFC 5054, 3072-bit prime group).
// Corresponds to pyatv's pyatv/auth/hap_srp.py + srptools.
//
// HAP's Pair-Setup uses SRP: username = "Pair-Setup", password = PIN, hash = SHA512.
// All calculations use BigUInt (unsigned big integers), with semantics strictly aligned
// to Python's pow/% (negative bases are reduced before computing).

import Foundation
import CryptoKit
import BigInt

public enum SRP6a {
    /// 3072-bit prime from RFC 5054 Appendix A.
    static let primeHex = """
FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74
020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437
4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED
EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05
98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB
9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B
E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718
3995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33
A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7
ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864
D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E2
08E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF
""".filter { !$0.isWhitespace }

    static let prime: BigUInt = BigUInt(primeHex, radix: 16)!
    static let generator: BigUInt = BigUInt(5)
    /// Byte length of the prime (3072 / 8).
    static let primeByteCount = 384

    // MARK: - Basic utilities

    static func sha512(_ data: Data) -> Data {
        let digest = SHA512.hash(data: data)
        return digest.withUnsafeBytes { Data($0) }
    }

    /// Integer → minimal big-endian bytes. Corresponds to srptools' int_to_bytes (0 → single byte 0x00).
    static func intToBytes(_ value: BigUInt) -> Data {
        if value.isZero { return Data([0]) }
        return value.serialize()
    }

    /// Integer → fixed prime byte length (left-padded with zeros). Corresponds to srptools' pad.
    static func pad(_ value: BigUInt) -> Data {
        let bytes = intToBytes(value)
        let paddingCount = primeByteCount - bytes.count
        var padded = Data(repeating: 0, count: paddingCount)
        padded.append(bytes)
        return padded
    }

    /// Concatenates multiple Data chunks then applies SHA512, returning an integer. Corresponds to srptools' hash(as_bytes=False).
    static func hInt(_ chunks: [Data]) -> BigUInt {
        var data = Data()
        for chunk in chunks { data.append(chunk) }
        return BigUInt(sha512(data))
    }

    /// Concatenates multiple Data chunks then applies SHA512, returning bytes. Corresponds to srptools' hash(as_bytes=True).
    static func hBytes(_ chunks: [Data]) -> Data {
        var data = Data()
        for chunk in chunks { data.append(chunk) }
        return sha512(data)
    }

    // MARK: - SRP computation

    /// x = H(salt | H(username ":" password))
    static func computeX(username: String, password: String, salt: Data) -> BigUInt {
        let inner = sha512(Data("\(username):\(password)".utf8))
        return hInt([salt, inner])
    }

    /// v = g^x mod N
    static func computeVerifier(x: BigUInt) -> BigUInt {
        generator.power(x, modulus: prime)
    }

    /// k = H(N | PAD(g))
    static func computeMultiplier() -> BigUInt {
        hInt([intToBytes(prime), pad(generator)])
    }

    /// u = H(PAD(A) | PAD(B))
    static func computeCommonSecret(clientPublic: BigUInt, serverPublic: BigUInt) -> BigUInt {
        hInt([pad(clientPublic), pad(serverPublic)])
    }

    /// S = (B - k*v)^(a + u*x) mod N
    static func computePremaster(
        serverPublic: BigUInt, multiplier: BigUInt, verifier: BigUInt,
        clientPrivate: BigUInt, commonSecret: BigUInt, x: BigUInt
    ) -> BigUInt {
        // base = (B - k*v) mod N (non-negative, aligned with Python's pow semantics for a negative base)
        let base = (BigInt(serverPublic) - BigInt(multiplier) * BigInt(verifier))
            .modulus(BigInt(prime)).magnitude
        let exponent = clientPrivate + commonSecret * x
        return base.power(exponent, modulus: prime)
    }

    /// K = H(S)
    static func computeSessionKey(premaster: BigUInt) -> Data {
        sha512(intToBytes(premaster))
    }

    /// M = H(H(N) XOR H(g) | H(I) | s | A | B | K)
    static func computeProof(
        username: String, salt: Data,
        clientPublic: BigUInt, serverPublic: BigUInt, sessionKey: Data
    ) -> Data {
        let hN = hInt([intToBytes(prime)])
        let hg = hInt([intToBytes(generator)])
        let hNxorHg = (BigInt(hN) ^ BigInt(hg)).magnitude
        let hI = hInt([Data(username.utf8)])
        return hBytes([
            intToBytes(hNxorHg),
            intToBytes(hI),
            salt,
            intToBytes(clientPublic),
            intToBytes(serverPublic),
            sessionKey,
        ])
    }

    /// M2 = H(A | M | K)
    static func computeProofHash(clientPublic: BigUInt, proof: Data, sessionKey: Data) -> Data {
        hBytes([intToBytes(clientPublic), proof, sessionKey])
    }

    /// Full client process: takes the server public key B and salt as input,
    /// outputs (minimal-bytes clientPublic A, sessionKey K, proof M, proofHash M2).
    /// B % N == 0 is treated as invalid (corresponds to srptools' security check) and returns nil.
    public static func process(
        username: String, password: String, clientPrivateBytes: Data,
        serverPublicBytes: Data, salt: Data
    ) -> (clientPublic: Data, sessionKey: Data, proof: Data, proofHash: Data)? {
        let serverPublic = BigUInt(serverPublicBytes)
        guard serverPublic % prime != 0 else { return nil }

        let clientPrivate = BigUInt(clientPrivateBytes)
        let clientPublic = generator.power(clientPrivate, modulus: prime)
        let x = computeX(username: username, password: password, salt: salt)
        let verifier = computeVerifier(x: x)
        let multiplier = computeMultiplier()
        let commonSecret = computeCommonSecret(clientPublic: clientPublic, serverPublic: serverPublic)
        let premaster = computePremaster(
            serverPublic: serverPublic, multiplier: multiplier, verifier: verifier,
            clientPrivate: clientPrivate, commonSecret: commonSecret, x: x)
        let sessionKey = computeSessionKey(premaster: premaster)
        let proof = computeProof(
            username: username, salt: salt,
            clientPublic: clientPublic, serverPublic: serverPublic, sessionKey: sessionKey)
        let proofHash = computeProofHash(clientPublic: clientPublic, proof: proof, sessionKey: sessionKey)
        return (intToBytes(clientPublic), sessionKey, proof, proofHash)
    }
}
