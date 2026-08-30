// AppleTVControl — Apple TV control protocol stack implemented in native Swift.
//
// Goal: replace the embedded Python + pyatv, shrinking the DMG from ~40MB to 1-3MB.
//
// Module layout:
//   - Discovery:     Bonjour (NetService) device discovery
//   - Crypto:        SRP-6a / TLV8 / ChaCha20-Poly1305 wrappers
//   - Serialization: opack encode/decode
//   - Companion:     Companion pairing (Pair-Setup/Pair-Verify) and encrypted channel
//   - MRP:           MediaRemote control messages (key press/status/apps/text)

public enum AppleTVControl {
    /// Library version, incremented with each release.
    public static let version = "0.1.0"
}
