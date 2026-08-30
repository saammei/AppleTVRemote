# AppleTVRemote — Project Notes (Quick Start for New Agents)

macOS menu bar app for controlling Apple TV on the local network. SwiftUI UI + native Swift
protocol stack (`AppleTVControl`), **no Python dependency**, release package is only ~3.6 MB.

## ⚠️ Critical Constraints (Must Follow)

- **Personal project — never leak any company information.** All git operations (commit / tag /
  push) must use the personal identity: `meishaoming <shaoming.mei@qq.com>`. Before committing,
  confirm with
  `git config --local user.name meishaoming && git config --local user.email shaoming.mei@qq.com`
  (this repo is already configured; double-check before making changes). No company names or
  internal links in commit messages, tag notes, or docs.
- **Tell the user before pushing.** Don't `git push` on your own — first explain what will be
  pushed and where, and push only after confirmation.
- The main development branch is `native-swift`; `main` now contains the native Swift
  implementation as well (the old Python version lives only in git history).

## Current Status

- **Releases**: v1.1.0 and v1.1.1 are already released; the latest release will be v1.1.2. The
  native Swift protocol stack has fully replaced Python/pyatv. Device discovery, Companion pairing
  (SRP+Curve25519), connection control (keys/media/power/apps/text), and MRP now-playing metadata
  are all implemented, tested, and wired into the app. DMG size dropped from ~40MB to ~3.6MB.
- **Feature scope**: remote buttons + now playing + app launcher + text input. **AirPlay audio is
  not supported.**
- **Branches**: `native-swift` = main development branch (for now); `main` has been merged to the
  native Swift version, so both branches now contain native Swift code — the old Python version
  exists only in git history.

## Architecture & Docs

Details are in `docs/`; read as needed:

- **[docs/architecture.md](docs/architecture.md)** — system layering, protocol stack, module
  responsibilities, key APIs
- **[docs/development.md](docs/development.md)** — environment, building, testing, manual
  packaging without Xcode
- **[docs/release.md](docs/release.md)** — versioning mechanism, CI release process

## Quick Commands

```bash
# Self-test for the protocol stack (the only test entry point, no XCTest)
cd AppleTVControl && swift run AppleTVControlTests

# Build the app (requires full Xcode)
xcodebuild -project AppleTVRemote.xcodeproj -scheme AppleTVRemote \
  -configuration Release -derivedDataPath DerivedData \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY="-" build

# Release: push a tag to trigger CI (version is parsed from the tag)
git tag -a v1.2.0 -m "..." && git push origin v1.2.0
```

## Directory Overview

- `AppleTVControl/` — native Swift package (discovery / pairing / connection / control / metadata)
- `AppleTVRemote/` — app source (SwiftUI, PBXFileSystemSynchronized auto-discovers files)
- `AppleTVRemote.xcodeproj/` — Xcode project (references the local package `AppleTVControl`)
- `scripts/make_icon.swift` — app icon generation
- `.github/workflows/release.yml` — CI build + release
