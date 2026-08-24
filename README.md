# Apple TV 遥控器（macOS）

一个 macOS 菜单栏应用，用来在局域网内控制 Apple TV。SwiftUI 界面 + 原生 Swift 协议栈
（`AppleTVControl`），不依赖 Python，下载即用。

## 功能

- 自动发现局域网中的 Apple TV（mDNS 扫描）
- 首次配对（Apple TV 屏幕显示 4 位 PIN 码），凭据保存在本机
- 遥控：方向键、确认、返回、主屏幕、播放/暂停、上一首/下一首、音量、电源、快进/快退
- 应用启动器（从 Apple TV 已安装应用列表启动）
- 正在播放信息（标题、艺术家、封面、进度）
- 启动后自动重连上次连接的电视
- 面板打开时直接用 Mac 键盘控制

## 安装

需要 Apple Silicon 芯片的 Mac(M1 及更新;Intel 机型暂不支持)。

1. 到 [Releases](../../releases/latest) 下载最新版 `AppleTVRemote-*.dmg`
2. 打开 DMG，把 `AppleTVRemote` 拖进「应用程序」
3. 首次打开：因为应用未使用 Apple 开发者签名（免费发布），macOS 会拦截。
   在「应用程序」里**右键点图标 → 打开**，再点一次「打开」即可（只需一次）。
   或者用命令行放行：

   ```bash
   xattr -dr com.apple.quarantine "/Applications/AppleTVRemote.app"
   ```

4. 应用没有 Dock 图标，只在右上角菜单栏显示一个遥控器图标

## 首次使用

1. 点菜单栏遥控器图标 → 右上角齿轮（设置）
2. 点「扫描设备」，选中你的 Apple TV
3. 点「配对」，Apple TV 屏幕上会显示 4 位 PIN 码，输入后确认
4. 点「连接」。之后每次启动应用会自动重连

> 首次扫描时 macOS 会询问「查找并连接到本地网络上的设备」，请点**允许**；
> 如果没弹窗，去 系统设置 → 隐私与安全性 → 本地网络 里手动勾选本应用。

## 键盘控制（面板打开时）

| 按键 | 功能 |
|---|---|
| ↑ ↓ ← → | 方向键 |
| 回车 | 确认 |
| Esc | 返回 |
| 空格 | 播放 / 暂停 |
| ⌘↑ / ⌘↓ | 音量加 / 减 |
| ⌘→ / ⌘← | 下一首 / 上一首 |
| ⌥→ / ⌥← | 快进 / 快退 10 秒 |

## 架构

```
┌──────────────────────────┐        ┌─────────────────────────────┐
│  SwiftUI 菜单栏应用       │  直接调用 │  AppleTVControl (Swift 包)     │
│  RemoteView / Settings   │ ───────► │  Discovery / Companion / MRP │
│  ATVBridge               │  进程内    └──────────────┬──────────────┘
└──────────────────────────┘                          │ Companion / MRP 协议
                                                      ▼
                                                    Apple TV
```

应用不再启动 Python 子进程。`ATVBridge` 直接调用本地 Swift 包 `AppleTVControl`，
在进程内完成 mDNS 发现、Companion 配对（SRP + Curve25519）、连接与控制，以及
MRP 正在播放元数据。发布包体积因此从 ~40MB 降到几 MB。

## 从源码构建

```bash
# 构建(命令行;首次会自动解析 Swift 包依赖 swift-protobuf / BigInt)
xcodebuild -project AppleTVRemote.xcodeproj -scheme AppleTVRemote \
  -configuration Debug -derivedDataPath DerivedData build

# 或直接在 Xcode 里 ⌘R 运行
open AppleTVRemote.xcodeproj
```

想换应用图标:改 `scripts/make_icon.swift` 里的渐变色/符号,运行
`swift scripts/make_icon.swift` 重新生成。

## 发布新版本

```bash
git tag v1.1.0
git push origin v1.1.0
```

CI(.github/workflows/release.yml)会自动:构建 arm64 应用 → 打包 DMG → 发布 GitHub Release。

## 常见问题

### 扫描不到 Apple TV

- 确认 Mac 和 Apple TV 在同一个局域网（同一路由器/VLAN）
- 确认系统已允许本应用访问本地网络(见「首次使用」)
- 公司网络或访客网络可能禁止 mDNS 组播

### 连接失败 / 配对失败

- 连接前确保已在设置里完成「配对」（未配对时连接会提示）
- 重新配对：先在设置里「断开」，再对同一设备「配对」
- 如果之前配对过但凭据失效，删掉
  `~/Library/Application Support/AppleTVRemote/credentials.json` 后重新配对

### 音量按钮无效

Apple TV 的音量通常由 HDMI-CEC/红外控制接收器完成，部分设备/协议不提供音量
控制。方向键、确认、菜单、播放暂停等核心按键不受影响。

### 唤醒

Apple TV 处于睡眠时可能无法连接。可以先点「连接」触发唤醒（Companion 协议会
尝试唤醒），或在设置里再次扫描后连接。

## 隐私

配对凭据（相当于这把 Mac 在 Apple TV 上的「钥匙」）只保存在本机
`~/Library/Application Support/AppleTVRemote/credentials.json`，不会上传到任何地方。
应用不联网，不需要网络之外的任何权限。
