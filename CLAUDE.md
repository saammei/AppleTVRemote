# AppleTVRemote — 项目说明（新 agent 快速上手）

macOS 菜单栏应用，用于在局域网内控制 Apple TV。SwiftUI 界面 + 原生 Swift 协议栈
（`AppleTVControl`），**不依赖 Python**，发布包仅 ~3.6 MB。

## ⚠️ 关键约束（务必遵守）

- **个人项目，严禁泄露任何公司信息。** 任何 git 操作（commit / tag / push）都必须使用
  个人身份：`meishaoming <shaoming.mei@qq.com>`。提交前用
  `git config --local user.name meishaoming && git config --local user.email shaoming.mei@qq.com`
  确认（本仓库已配好，改动前复查一遍）。提交信息、tag 注释、文档里都不要出现公司名/内部链接。
- **推送前先告知用户。** 不要擅自 `git push`，先说明要推什么、推到哪里，得到确认再推。
- 主开发分支是 `native-swift`；`main` 仍是旧 Python 版（暂不合回）。

## 当前状态（完成情况）

- **已完成并发布 v1.1.0**：原生 Swift 协议栈全面替代 Python/pyatv。设备发现、Companion 配对
  （SRP+Curve25519）、连接控制（按键/媒体/电源/应用/文本）、MRP 正在播放元数据，均已实现、
  测试通过、前端接入，DMG 从 ~40MB 降到 ~3.6MB。
- **功能范围**：遥控按钮 + 正在播放 + 应用启动 + 文本输入。**不支持 AirPlay 音频**。
- **分支**：`native-swift` = 主开发分支；`main` = 旧 Python 版（**暂不合回**，用户明确说先不回合）。

## 架构与文档

详细说明见 `docs/`，按需阅读：

- **[docs/architecture.md](docs/architecture.md)** — 系统分层、协议栈、模块职责、关键 API
- **[docs/development.md](docs/development.md)** — 环境、构建、测试、本机无 Xcode 的手工打包
- **[docs/release.md](docs/release.md)** — 版本号机制、CI 发布流程

## 快速命令

```bash
# 协议栈自测（唯一测试入口，无 XCTest）
cd AppleTVControl && swift run AppleTVControlTests

# 构建应用（需完整 Xcode）
xcodebuild -project AppleTVRemote.xcodeproj -scheme AppleTVRemote \
  -configuration Release -derivedDataPath DerivedData \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY="-" build

# 发布：打 tag 触发 CI（版本号从 tag 解析）
git tag -a v1.2.0 -m "..." && git push origin v1.2.0
```

## 目录速览

- `AppleTVControl/` — 原生 Swift 包（发现 / 配对 / 连接 / 控制 / 元数据）
- `AppleTVRemote/` — 应用源码（SwiftUI，PBXFileSystemSynchronized 自动发现文件）
- `AppleTVRemote.xcodeproj/` — 工程（引用了本地包 `AppleTVControl`）
- `scripts/make_icon.swift` — 应用图标生成
- `.github/workflows/release.yml` — CI 构建 + 发布
