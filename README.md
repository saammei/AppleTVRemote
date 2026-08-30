# Apple TV Remote (macOS)

A menu bar app for controlling Apple TV on the local network. Built with SwiftUI and a native
Swift protocol stack — no Python, no runtime dependencies. Download the DMG and use.

## Features

- Auto-discovers Apple TVs on the local network
- Remote control: directional keys, select, back, home, play/pause, previous/next, volume, power,
  fast-forward/rewind
- Launches apps installed on the Apple TV
- Now playing info: title, artist, artwork, progress
- Control with your Mac keyboard while the panel is open
- Auto-reconnects to the last used TV on launch

## Install

Requires an Apple Silicon Mac.

1. Download the latest `AppleTVRemote-*.dmg` from [Releases](../../releases/latest)
2. Open the DMG and drag `AppleTVRemote` into Applications
3. First launch: the app isn't signed with an Apple Developer identity, so macOS blocks it once.
   Double-click the app, click **OK** on the warning, then open **System Settings → Privacy &
   Security**, find **AppleTVRemote** and click **Open Anyway**, then **Open** again.
   (Alternative: `xattr -dr com.apple.quarantine "/Applications/AppleTVRemote.app"` in Terminal.)
4. The app lives in the menu bar (remote icon, top-right) — no Dock icon

## First Use

1. Click the menu bar icon → the gear icon (Settings)
2. Click **Scan**, select your Apple TV
3. Click **Pair** — the Apple TV shows a 4-digit PIN; enter it and confirm
4. Click **Connect**. After that the app reconnects automatically.

> On the first scan, allow Local Network access when macOS asks. If no dialog appears, enable the
> app under System Settings → Privacy & Security → Local Network.

## Keyboard (while the panel is open)

| Key | Function |
|---|---|
| ↑ ↓ ← → | Directional keys |
| Enter | Select |
| Esc | Back |
| Space | Play / Pause |
| ⌘↑ / ⌘↓ | Volume up / down |
| ⌘→ / ⌘← | Next / Previous track |
| ⌥→ / ⌥← | Fast-forward / Rewind 10 s |

## FAQ

- **Can't find the Apple TV** — same network (router/VLAN), Local Network permission granted;
  corporate/guest networks may block mDNS.
- **Connection / pairing fails** — pair first, then connect. Stale credentials? Delete
  `~/Library/Application Support/AppleTVRemote/credentials.json` and pair again.
- **Volume doesn't work** — volume is handled by HDMI-CEC/IR; some setups don't support it.
- **TV asleep** — click Connect to trigger a wake-up, then retry.

## Privacy

Pairing credentials are stored only locally in
`~/Library/Application Support/AppleTVRemote/credentials.json` and never uploaded. No network
permissions beyond local network access.
