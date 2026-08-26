# 发布流程

## 一、版本号机制

版本号**来自 git tag，不来自分支**。`.github/workflows/release.yml` 里：

```yaml
on:
  push:
    tags: ["v*"]          # 打 v* tag 触发
  workflow_dispatch:      # 手动触发（版本号固定为 "dev"）
```

```yaml
- name: 计算版本号
  run: |
    if [[ "${GITHUB_REF_NAME}" == v* ]]; then
      echo "VERSION=${GITHUB_REF_NAME#v}" >> "$GITHUB_ENV"   # v1.1.0 → 1.1.0
    else
      echo "VERSION=dev" >> "$GITHUB_ENV"
    fi
```

`VERSION` 随后通过 `MARKETING_VERSION="$VERSION"` 注入 `xcodebuild`，决定 App 的
「关于」版本号与 DMG 文件名 `AppleTVRemote-<VERSION>.dmg`。

**版本号规则**：语义化版本。历史 tag：`v1.0.0`、`v1.0.1`、`v1.1.0`（v1.1.0 = 原生 Swift
架构改造）。常规功能/修复升 patch 或 minor。

## 二、标准发布步骤

```bash
# 0. 确认身份（个人项目，严禁公司信息）
git config --local user.name meishaoming
git config --local user.email shaoming.mei@qq.com
git log -1 --format='%an <%ae>'   # 复查

# 1. 在开发分支（如 native-swift）上完成并提交改动

# 2. 打带注释的 tag，指向要发布的提交（不要求 tag 在 main 上）
git tag -a v1.2.0 -m "v1.2.0: <一句话说明>"
git show v1.2.0 --no-patch --format='%h %s'   # 确认指向正确提交

# 3. 推送 tag → 触发 CI 自动构建 + 发布 GitHub Release
git push origin v1.2.0
```

CI 全流程（macos-15 runner，约 8~20 分钟）：

1. **协议栈自测**：`cd AppleTVControl && swift run AppleTVControlTests`
2. **构建**：`xcodebuild ... -configuration Release ARCHS=arm64 CODE_SIGN_IDENTITY="-" build`
3. **签名**：`codesign --force --deep --sign -`（ad-hoc）
4. **打包 DMG**：`hdiutil create ... -format UDZO AppleTVRemote-<VERSION>.dmg`
5. **发布**：tag 触发时 `softprops/action-gh-release` 自动创建 Release 并上传 DMG；
   Release 正文会自动带上「首次安装」说明（含 Gatekeeper 放行步骤）和基于上一 tag
   的自动更新日志；`workflow_dispatch` 手动触发时只上传为 artifact（不发 Release）。

## 三、验证结果

- Release 页：`https://github.com/saammei/AppleTVRemote/releases/tag/v<版本>`
- 直接下载：`https://github.com/saammei/AppleTVRemote/releases/download/v<版本>/AppleTVRemote-<版本>.dmg`
- 体积基准：**~3.6 MB**（原生 Swift 版；旧 Python 版为 40+MB）。用 HEAD 请求拿真实字节数：

  ```bash
  curl -sIL "https://github.com/saammei/AppleTVRemote/releases/download/v1.1.0/AppleTVRemote-1.1.0.dmg" \
    | grep -i content-length | tail -1
  ```

## 四、注意事项

- **分支关系**：主开发在 `native-swift`，`main` 仍是旧 Python 版（暂未合回）。tag 可以
  直接打在 `native-swift` 的提交上触发发布，不必先合 `main`。
- **公开仓库**：`saammei/AppleTVRemote` 是公开的，发布即对外可见。tag 注释、Release 说明
  里不要出现公司信息。
- **`workflow_dispatch` 的坑**：手动触发只对**默认分支（main）**上存在的 workflow 文件
  生效。若 workflow 改动只在 `native-swift`，手动触发会跑 main 上的旧版流程——此时应改用
  tag 触发，或先把 workflow 合回 main。
- **无 `gh` CLI**：本机未装 `gh`，CI 状态可通过网页（`/actions`、`/releases`）或用
  `curl` 轮询 releases 页确认。
