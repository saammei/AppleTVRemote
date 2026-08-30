# Apple TV Remote (macOS)

A macOS menu bar app for controlling Apple TV on the local network. SwiftUI UI + native Swift
protocol stack (`AppleTVControl`), no Python dependency, download and run.

## Features

- Auto-discover Apple TVs on the local network (mDNS scan)
- First-time pairing (Apple TV shows a 4-digit PIN on screen), credentials stored locally
- Remote control: directional keys, select, back, home, play/pause, previous/next track, volume,
  power, fast-forward/rewind
- App launcher (launch apps from the list of installed apps on the Apple TV)
- Now playing info (title, artist, artwork, progress)
- Auto-reconnect to the last connected TV on launch
- Use your Mac keyboard to control when the panel is open

## Installation

Requires an Apple Silicon Mac (M1 or newer; Intel models are not supported yet).

1. Download the latest `AppleTVRemote-*.dmg` from [Releases](../../releases/latest)
2. Open the DMG and drag `AppleTVRemote` into Applications
3. First launch: the app is not signed with an Apple Developer identity (distributed free), so
   macOS blocks it once; after you approve it, it will open normally from then on. Pick one of
   these two ways:

   **Option 1: Approve via System Settings (recommended, no terminal needed)**

   1. Double-click the icon. If a dialog says Apple can't verify AppleTVRemote is free of
      malware that could harm your Mac or leak your privacy, click **OK**
   2. Open **System Settings → Privacy & Security**, scroll down to the Security section
   3. Find **AppleTVRemote** in the list and click **Open Anyway** on the right
   4. Click **Open** once more in the confirmation dialog — the app now works normally

   > ⚠️ If you don't see AppleTVRemote in the list at step 2, that's normal — go back to
   > Applications and **double-click the icon again**, then reopen System Settings and the option
   > will appear.

   **Option 2: Approve from the command line**

   ```bash
   xattr -dr com.apple.quarantine "/Applications/AppleTVRemote.app"
   ```

4. The app has no Dock icon; it only shows a remote icon in the menu bar at the top-right

## First Use

1. Click the menu bar remote icon → the gear icon (Settings) in the top-right
2. Click "Scan for Devices", then select your Apple TV
3. Click "Pair" — the Apple TV shows a 4-digit PIN on screen; enter it and confirm
4. Click "Connect". On subsequent launches the app auto-reconnects.

> On the first scan, macOS asks to find and connect to devices on your local network — click
> **Allow**. If no dialog appears, go to System Settings → Privacy & Security → Local Network and
> enable this app manually.

## Keyboard Control (While the Panel Is Open)

| Key | Function |
|---|---|
| ↑ ↓ ← → | Directional keys |
| Enter | Select |
| Esc | Back |
| Space | Play / Pause |
| ⌘↑ / ⌘↓ | Volume up / down |
| ⌘→ / ⌘← | Next / Previous track |
| ⌥→ / ⌥← | Fast-forward / Rewind 10 s |

## Architecture

```
┌────────────────────────────┐           ┌──────────────────────────────┐
│  SwiftUI Menu Bar App      │  direct   │  AppleTVControl (Swift pkg)  │
│  RemoteView / Settings     │ ────────► │  Discovery / Companion / MRP │
│  ATVBridge                 │ in-process └──────────────┬─────────────────┘
└────────────────────────────┘           │ Companion / MRP protocol
                                                         ▼
                                                     Apple TV
```

The app no longer spawns a Python subprocess. `ATVBridge` directly calls the local Swift package
`AppleTVControl`, doing mDNS discovery, Companion pairing (SRP + Curve25519), connection and
control, and MRP now-playing metadata all in-process. That is why the release package dropped
from ~40MB to a few MB.

## Build from Source

```bash
# Build from the command line (resolves Swift package deps swift-protobuf / BigInt on first build)
xcodebuild -project AppleTVRemote.xcodeproj -scheme AppleTVRemote \
  -configuration Debug -derivedDataPath DerivedData build

# Or just run with ⌘R in Xcode
open AppleTVRemote.xcodeproj
```

To change the app icon: edit the gradient colors/symbols in `scripts/make_icon.swift`, then run
`swift scripts/make_icon.swift` to regenerate.

## Release a New Version

```bash
git tag v1.1.0
git push origin v1.1.0
```

CI (`.github/workflows/release.yml`) automatically: builds the arm64 app → packages the DMG →
publishes a GitHub Release.

## FAQ

### Can't Find the Apple TV

- Make sure the Mac and Apple TV are on the same local network (same router/VLAN)
- Make sure this app is allowed to access the local network in System Settings (see First Use)
- Corporate or guest networks may block mDNS multicast

### Connection / Pairing Fails

- Make sure you've paired in Settings before connecting (connecting while unpaired shows a prompt)
- To re-pair: Disconnect in Settings first, then Pair the same device again
- If credentials from a previous pairing are stale, delete
  `~/Library/Application Support/AppleTVRemote/credentials.json` and pair again

### Volume Buttons Don't Work

Apple TV volume is usually handled by the HDMI-CEC/IR receiver; some devices/protocols don't
provide volume control. Core buttons — directional keys, select, menu, play/pause — are unaffected.

### Wake-Up

An Apple TV that's asleep may refuse connections. Try clicking Connect first to trigger a wake
(the Companion protocol attempts one), or scan again in Settings and connect.

## Privacy

Pairing credentials (the equivalent of this Mac's key on your Apple TV) are stored only locally in
`~/Library/Application Support/AppleTVRemote/credentials.json` and never uploaded anywhere. The
app doesn't phone home and needs no permissions beyond the local network.
