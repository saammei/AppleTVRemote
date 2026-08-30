# Development Guide

## 1. Environment Requirements

- macOS 14+ (deployment target 14.0), Apple Silicon (arm64).
- Swift 5.9+ / Xcode 16+ (`objectVersion 77`; the project uses `PBXFileSystemSynchronizedRootGroup`).
- Dependencies are resolved automatically by SPM: `swift-protobuf`, `BigInt` (first build needs
  network access).

> ⚠️ This machine currently only has **CommandLineTools, no full Xcode**, so `xcodebuild` is
> unavailable. See "Manual packaging without Xcode" below.

## 2. Build & Test

### Protocol Stack Self-Test (No XCTest — Custom Assertion Framework)

```bash
cd AppleTVControl
swift run AppleTVControlTests
# Prints "✅ All tests passed" on success
```

The test entry point is `Sources/AppleTVControlTests/main.swift`, which calls
`runCompanionTests() / runMRPTests() / runCryptoTests() / runDiscoveryTests() /
runBinaryPlistTests() / runOPACKTests() / runCredentialsStoreTests()` etc., one by one.

### Building the App (Requires Full Xcode)

```bash
xcodebuild -project AppleTVRemote.xcodeproj -scheme AppleTVRemote \
  -configuration Release -derivedDataPath DerivedData \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY="-" build
```

Or just `open AppleTVRemote.xcodeproj` and hit ⌘R. The product is at
`DerivedData/Build/Products/Release/AppleTVRemote.app`.

### Manual Packaging Without Xcode (Verified on This Machine)

Approach: use the Swift toolchain to compile the 5 app source files + the local package into an
executable, then assemble the `.app` by hand.

```bash
# 1. Create a temporary SPM executable package (depends on the local AppleTVControl)
mkdir -p /tmp/atv-app-build/Sources/ATVApp
cp AppleTVRemote/AppleTVRemote/*.swift /tmp/atv-app-build/Sources/ATVApp/
# Package.swift: executableTarget(name:"ATVApp", depends on .product("AppleTVControl"), path pointing at the local AppleTVControl)

# 2. Compile
cd /tmp/atv-app-build && swift build -c release
#    → .build/release/ATVApp (~9MB, unstripped)

# 3. Assemble the .app
mkdir -p AppleTVRemote.app/Contents/{MacOS,Resources}
cp .build/release/ATVApp AppleTVRemote.app/Contents/MacOS/AppleTVRemote
# Write Info.plist (replace variables like $(EXECUTABLE_NAME) with real values, bundle id = com.meishaoming.AppleTVRemote)
# Icon: iconutil -c icns AppIcon.iconset -o Contents/Resources/AppIcon.icns
#   (the iconset PNGs come straight from Assets.xcassets/AppIcon.appiconset/, names already match)

# 4. Sign + install + run
codesign --force --deep --sign - AppleTVRemote.app
cp -R AppleTVRemote.app /Applications/ && open /Applications/AppleTVRemote.app
```

Note: `actool` (Xcode-only) is unavailable, so the asset catalog cannot be compiled; the `.icns`
must be built manually from PNGs with `iconutil`.

## 3. Code Structure Quick Reference

```
AppleTVRemote/
├── AppleTVRemoteApp.swift   @main entry + AppDelegate (single-instance detection)
├── ATVBridge.swift          Bridge layer (discovery/pairing/connection/control/status, the only file importing AppleTVControl)
├── Models.swift             ATVDevice / NowPlaying / RemoteApp / ConnectionState / RemoteKey
├── RemoteView.swift         Main panel UI (buttons + keyboard capture + now playing)
└── SettingsView.swift       Settings (scan/pair/connect)
AppleTVControl/
├── Package.swift            Product AppleTVControl (library) + AppleTVControlTests (executable)
└── Sources/AppleTVControl/  Discovery / Companion / MRP / Crypto / Storage
```

## 4. Common Pitfalls

- **File-system-synchronized project**: the target in `AppleTVRemote.xcodeproj` uses
  `PBXFileSystemSynchronizedRootGroup`, so adding/removing `.swift` files under `AppleTVRemote/`
  needs **no pbxproj changes** (auto-discovered). Changing `Info.plist`, dependencies, or build
  settings still requires editing the pbxproj.
- **macOS's BSD sed does not support `\b`**: use the `Edit` tool for bulk replacements, or sed's
  `[[:<:]]`/`[[:>:]]`.
- **`ATVDevice` naming collision**: the package's device type is `DiscoveredDevice`, while the
  app-layer type is `ATVDevice` (don't mix them up; `ATVBridge.appDevice(from:)` does the
  conversion).
- **Local network permission**: the first scan requires the user to allow "Local Network";
  `Info.plist` already includes `NSLocalNetworkUsageDescription`.
- **Credential location**: `~/Library/Application Support/AppleTVRemote/credentials.json`.
- **Volume buttons**: some devices/protocols don't expose volume control (HDMI-CEC/IR), which is
  normal and doesn't affect the core buttons.
