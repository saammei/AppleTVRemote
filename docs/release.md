# Release Process

## 1. Versioning

The version number **comes from the git tag, not from the branch**. In
`.github/workflows/release.yml`:

```yaml
on:
  push:
    tags: ["v*"]          # Triggered by a v* tag push
  workflow_dispatch:      # Manual trigger (version is fixed to "dev")
```

```yaml
- name: Compute version
  run: |
    if [[ "${GITHUB_REF_NAME}" == v* ]]; then
      echo "VERSION=${GITHUB_REF_NAME#v}" >> "$GITHUB_ENV"   # v1.1.0 → 1.1.0
    else
      echo "VERSION=dev" >> "$GITHUB_ENV"
    fi
```

`VERSION` is then injected into `xcodebuild` via `MARKETING_VERSION="$VERSION"`, determining the
app's About version and the DMG filename `AppleTVRemote-<VERSION>.dmg`.

**Versioning rule**: semantic versioning. Historical tags: `v1.0.0`, `v1.0.1`, `v1.1.0`,
`v1.1.1` (v1.1.0 = the native Swift rewrite); v1.1.2 is the next planned release. Regular
features/fixes bump patch or minor.

## 2. Standard Release Steps

```bash
# 0. Confirm identity (personal project — no company info)
git config --local user.name meishaoming
git config --local user.email shaoming.mei@qq.com
git log -1 --format='%an <%ae>'   # double-check

# 1. Finish and commit your changes on the development branch (e.g. native-swift)

# 2. Create an annotated tag pointing at the commit to release (the tag doesn't have to be on main)
git tag -a v1.2.0 -m "v1.2.0: <one-line description>"
git show v1.2.0 --no-patch --format='%h %s'   # confirm it points at the right commit

# 3. Push the tag → triggers CI to build and publish the GitHub Release
git push origin v1.2.0
```

Full CI flow (macos-15 runner, ~8-20 minutes):

1. **Protocol stack self-test**: `cd AppleTVControl && swift run AppleTVControlTests`
2. **Build**: `xcodebuild ... -configuration Release ARCHS=arm64 CODE_SIGN_IDENTITY="-" build`
3. **Sign**: `codesign --force --deep --sign -` (ad-hoc)
4. **Package DMG**: `hdiutil create ... -format UDZO AppleTVRemote-<VERSION>.dmg`
5. **Publish**: on a tag push, `softprops/action-gh-release` automatically creates the Release and
   uploads the DMG; the Release body automatically includes the "First Install" notes (with the
   Gatekeeper approval steps) and an auto-generated changelog based on the previous tag. A manual
   `workflow_dispatch` trigger only uploads as an artifact (no Release).

## 3. Verifying the Result

- Release page: `https://github.com/saammei/AppleTVRemote/releases/tag/v<version>`
- Direct download:
  `https://github.com/saammei/AppleTVRemote/releases/download/v<version>/AppleTVRemote-<version>.dmg`
- Size baseline: **~3.6 MB** (native Swift version; the old Python version was 40+MB). Get the
  actual byte count with a HEAD request:

  ```bash
  curl -sIL "https://github.com/saammei/AppleTVRemote/releases/download/v1.1.0/AppleTVRemote-1.1.0.dmg" \
    | grep -i content-length | tail -1
  ```

## 4. Notes & Caveats

- **Branch relationship**: main development happens on `native-swift`; `main` has been merged to
  the native Swift version (the old Python version lives only in git history). Tags can be made
  directly on commits on `native-swift` to trigger a release — no need to merge to `main` first.
- **Public repo**: `saammei/AppleTVRemote` is public — releases are immediately visible to
  everyone. No company information in tag notes or Release descriptions.
- **`workflow_dispatch` pitfall**: manual dispatch only picks up the workflow file on the
  **default branch (main)**. If workflow changes only exist on `native-swift`, a manual dispatch
  will run the workflow as it exists on main — in that case, trigger via a tag instead, or merge
  the workflow to main first.
- **No `gh` CLI**: `gh` is not installed on this machine; check CI status via the web UI
  (`/actions`, `/releases`) or poll the releases page with `curl`.
