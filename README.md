# Apple TV 遥控器（macOS）

一个 macOS 菜单栏应用，用来在局域网内控制 Apple TV。SwiftUI 界面 + [pyatv](https://github.com/postlund/pyatv) 驱动，
内置 Python 运行时，下载即用，无需安装任何依赖。

## 功能

- 自动发现局域网中的 Apple TV（mDNS 扫描）
- 首次配对（Apple TV 屏幕显示 4 位 PIN 码），凭据保存在本机
- 遥控：方向键、确认、返回、主屏幕、播放/暂停、上一首/下一首、音量、电源、快进/快退
- 应用启动器（从 Apple TV 已安装应用列表启动）
- 正在播放信息（标题、艺术家、封面、进度）
- 启动后自动重连上次连接的电视
- 面板打开时直接用 Mac 键盘控制

## 安装

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
┌─────────────────────────┐        JSON lines         ┌──────────────────────┐
│  SwiftUI 菜单栏应用      │ ◄──────────────────────►  │  Python bridge       │
│  RemoteView / Settings  │   stdin/stdout            │  (pyatv)             │
└─────────────────────────┘                           └──────────┬───────────┘
                                                                 │ Companion /
                                                                 │ AirPlay 协议
                                                                 ▼
                                                            Apple TV
```

应用本身不直接实现 Apple TV 协议，而是把按键、配对等操作翻译成 JSON 请求发给
`AppleTVRemote/Backend/bridge.py`，由 pyatv 完成实际的网络协议。发布包内嵌
独立的 Python 运行时（Intel 与 Apple Silicon 各一份），用户无需安装 Python。

## 从源码构建

```bash
# 1. 准备后端环境(开发时把 pyatv 装到 App Support,与发布版内嵌运行时互不干扰)
./scripts/setup.sh

# 2. 构建(命令行)
xcodebuild -project AppleTVRemote.xcodeproj -scheme AppleTVRemote \
  -configuration Debug -derivedDataPath DerivedData build

# 或直接在 Xcode 里 ⌘R 运行
open AppleTVRemote.xcodeproj
```

运行时 Python 的查找顺序:`ATV_BRIDGE_PYTHON` 环境变量 → app 包内
`Resources/python-<arch>/bin/python3`(发布版)→ `~/Library/Application Support/AppleTVRemote/venv/bin/python3`(开发版)。

想换应用图标:改 `scripts/make_icon.swift` 里的渐变色/符号,运行
`swift scripts/make_icon.swift` 重新生成。

## 发布新版本

```bash
git tag v1.1.0
git push origin v1.1.0
```

CI(.github/workflows/release.yml)会自动:构建通用二进制(Intel + Apple Silicon)→ 内嵌双架构 Python 运行时 →
打包 DMG → 发布 GitHub Release。

## 常见问题

### 扫描不到 Apple TV

- 确认 Mac 和 Apple TV 在同一个局域网（同一路由器/VLAN）
- 确认系统已允许本应用访问本地网络(见「首次使用」)
- 公司网络或访客网络可能禁止 mDNS 组播

### 连接失败 / 配对失败

- 在设置 → 后端 里查看日志，通常有具体原因
- 重新配对：先在设置里「断开」，再对同一设备「配对」
- 如果之前配对过但凭据失效，删掉
  `~/Library/Application Support/AppleTVRemote/pyatv.json` 后重新配对

### 音量按钮无效

Apple TV 的音量通常由 HDMI-CEC/红外控制接收器完成，pyatv 对部分设备/协议
不提供音量控制。方向键、确认、菜单、播放暂停等核心按键不受影响。

### 唤醒

Apple TV 处于睡眠时可能无法连接。可以先点「连接」触发唤醒（Companion 协议会
尝试唤醒），或在设置里再次扫描后连接。

## 隐私

配对凭据（相当于这把 Mac 在 Apple TV 上的「钥匙」）只保存在本机
`~/Library/Application Support/AppleTVRemote/pyatv.json`，不会上传到任何地方。
应用不联网，不需要网络之外的任何权限。
