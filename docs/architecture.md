# Architecture

## 1. Overall Structure

```
┌────────────────────────────────────────────────┐
│  AppleTVRemote.app (SwiftUI menu bar app)      │
│  RemoteView / SettingsView / Models            │
│  ATVBridge (bridge layer, ObservableObject)    │
└────────────────────────┬───────────────────────┘
                         │ direct calls (in-process, no subprocess)
┌────────────────────────┬───────────────────────┐
│  AppleTVControl (local Swift Package)          │
│  Discovery / Companion / MRP / Crypto / Storage│
└────────────────────────┬───────────────────────┘
                         │ TCP / mDNS
                         ▼
                      Apple TV
```

Core design: the previous "embedded Python runtime + pyatv subprocess" approach is replaced by an
**in-process native Swift protocol stack**. `ATVBridge` no longer spawns a subprocess; it directly
calls the `AppleTVControl` package's APIs. The release package therefore dropped from ~40MB to
~3.6MB.

## 2. AppleTVControl Package Layers

```
Sources/AppleTVControl/
├── Discovery/      Device discovery (Bonjour/NetService)
├── Companion/      Companion protocol (main control channel)
├── MRP/            MRP protocol (now-playing metadata)
├── Crypto/         Crypto primitives (SRP / Curve25519 / ChaCha20 / HKDF / TLV8)
├── Storage/        Credential persistence
└── AppleTVControl.swift   (package entry / public exports)
```

Dependencies (see `Package.swift`): `swift-protobuf` (from 1.38.0), `BigInt` (from 5.3.0).
Platform: `macOS 14+`.

### 2.1 Discovery — Device Discovery

- `DeviceDiscovery`: scans two Bonjour services with `NetServiceBrowser` —
  `_mediaremotetv._tcp` (MRP) and `_companion-link._tcp` (Companion), reporting via
  `onDevicesUpdated: (([DiscoveredDevice]) -> Void)?`.
- `DeviceAggregator`: merges the MRP + Companion services of the same device (keyed by
  `identifier`) into one.
- `DiscoveredDevice` (the core public type):

  ```swift
  public struct DiscoveredDevice {
      let identifier: String          // Unique device ID (from TXT record)
      let name: String
      let host: String
      let model: String
      let companionPort: Int?         // nil = Companion not supported
      let mrpPort: Int?               // nil = MRP not supported
      let txt: [String: String]
      var isCompanionSupported: Bool  // companionPort != nil
      var isMRPSupported: Bool        // mrpPort != nil
  }
  ```

### 2.2 Companion — Main Control Channel (Keys/Media/Power/Apps/Text)

Tech stack: TCP (`NWConnection` from `Network.framework`) → 4-byte frame header
`[FrameType(1) + len(3, big-endian)]` → OPACK encoding → encryption.

- **Pairing** (first time, Apple TV shows a 4-digit PIN):
  `CompanionPairSetupProcedure` (SRP-6a Pair-Setup) → yields `HapCredentials`.
- **Verification** (every connection): SRP + Curve25519 (Pair-Verify) → negotiates a session key.
- **Encryption**: `ChaCha20-Poly1305` (`CryptoKit`).
- **Connection layer**: `TCPCompanionConnection` (`Connection.swift` defines the abstract
  interface), `CompanionProtocol` (frame parsing + command dispatch), `SRPAuthHandler`.
- **API layer** `CompanionAPI` (exposed to the app; core methods):

  | Method | Purpose |
  |---|---|
  | `connect() / disconnect()` | Establish / close the connection |
  | `press(_ command: HidCommand)` | Press a key |
  | `mediaCommand(_: MediaControlCommand)` | Media command (next/previous track…) |
  | `skip(seconds:)` | Fast-forward / rewind |
  | `setVolume(_:)` | Set volume |
  | `turnOn() / turnOff()` | Power |
  | `fetchAttentionState() -> SystemStatus` | Power / screensaver state |
  | `appList() -> [String: String]` / `launchApp(_:)` | App list / launch an app |
  | `textSet / textAppend / textClear` | Text input (search field) |

  Enums: `HidCommand` (up/down/left/right/menu/select/home/volumeUp/volumeDown/siri/screensaver/
  sleep/wake/playPause/channel±/guide/page±), `MediaControlCommand`
  (play/pause/nextTrack/previousTrack/skipBy/fastForward…), `SystemStatus`
  (unknown=0/asleep=1/screensaver=2/awake=3/idle=4).

### 2.3 MRP — Now-Playing Metadata (Optional Channel)

Tech stack: TCP → **varint (LEB128) length prefix** → protobuf. MRP uses protobuf **extension
fields**, so they must be registered via `SimpleExtensionMap`; messages are encrypted with
`MRPCipher` (8-byte counter nonce).

- Connection: `MRPTCPConnection` + `MRPProtocol` (handshake with `MRPDeviceInfo`, which includes
  `osBuild`).
- API: `MRPAPI`, exposing `nowPlaying() -> MRPNowPlaying` and `artwork() -> Data?`.
- `MRPNowPlaying`: title / artist / album / mediaType / playbackState / position / duration.
- **`MRP/Generated/*.pb.swift` (77 files) are generated — do not edit by hand.** Their header
  comments note the source `Source: pyatv/protocols/mrp/protobuf/*.proto` — the .proto source
  files are not in this repo; they come from pyatv. To change MRP messages: take the `.proto`
  from pyatv and regenerate with `protoc` + the swift-protobuf generator.

### 2.4 Crypto / Storage

- `Crypto/`: `SRP` (SRP-6a), `ChaCha20`, `HKDF`, `TLV8`, `Credentials` (`HapCredentials`).
- `HapCredentials`: `ltpk / ltsk / atvId / clientId` (all `Data`), serialized via `detailString`
  / parsed via `parse`.
- `Storage/CredentialsStore`: persists `[String: HapCredentials]` (keyed by device identifier) as
  JSON `{ "<identifier>": "<detailString>" }`. API: `load() / credentials(for:) / save(_:for:) /
  remove(identifier:)`.

## 3. App Integration (ATVBridge)

`AppleTVRemote/ATVBridge.swift` is the single bridge layer between the app and the package (an
`ObservableObject` singleton).

- **Discovery**: `DeviceDiscovery.onDevicesUpdated` → converted into the app's own `ATVDevice`
  list.
- **Pairing**: `pairBegin` (calls `startPairing` to make the TV show a PIN) → `pairFinish` (calls
  `finishPairing`, saves credentials via `credentialsStore.save`).
- **Connection**: `performConnect` establishes Companion (required) + MRP (optional, wrapped in
  `do/catch`; a failure does not block control). Credentials live in
  `~/Library/Application Support/AppleTVRemote/credentials.json`.
- **Control**: `performKey` maps app keys to `HidCommand` (next/previous go through
  `mediaCommand`, skipForward/Backward go through `skip(seconds: ±10)`, topMenu reuses `menu`).
- **Status**: `pollStatus` (5-second timer) merges MRP metadata + Companion power state →
  `NowPlaying`.
- **Auto-reconnect**: `autoConnectIfNeeded` reads `lastDeviceIdentifier` from `UserDefaults`.

## 4. Protocol Reference

This implementation is reverse-engineered from / aligned with pyatv (header comments in several
files note "corresponds to pyatv …"). For protocol details, see the
[pyatv](https://github.com/postlund/pyatv) source: `pyatv/protocols/companion/` and
`pyatv/protocols/mrp/`.

> Note: **AirPlay audio is not supported**. Feature scope = remote buttons + now playing + app
> launcher + text input.
