# Apple TV 遥控器（macOS）

一个 macOS 菜单栏应用，用来在局域网内控制 Apple TV。

- 发现 Apple TV（mDNS 扫描）
- 首次配对（Apple TV 屏幕显示 4 位 PIN 码）
- 遥控：方向键 / 确认 / 菜单 / 主屏幕 / 播放暂停 / 上一个下一个 / 音量 / 电源
- 应用启动器（从 Apple TV 已安装应用列表启动应用）
- 正在播放信息（标题、艺术家、封面）
- 凭据保存在本机 `~/Library/Application Support/AppleTVRemote/pyatv.json`

## 架构

```
┌─────────────────────────┐        JSON lines         ┌──────────────────────┐
│  SwiftUI 菜单栏应用      │ ◄──────────────────────►  │  Python bridge       │
│  RemoteView / Settings  │   stdin/stdout            │  (pyatv 0.18)        │
└─────────────────────────┘                           └──────────┬───────────┘
                                                                 │ Companion /
                                                                 │ AirPlay 协议
                                                                 ▼
                                                            Apple TV
```

应用本身不直接实现 Apple TV 协议，而是把按键、配对等操作翻译成 JSON 请求发给
`AppleTVRemote/Backend/bridge.py`，由 pyatv 完成实际的网络协议。

## 安装

1. 安装后端环境（只需一次）：

   ```bash
   ./scripts/setup.sh
   ```

   脚本会把 pyatv 装到 `~/Library/Application Support/AppleTVRemote/venv`。

2. 打开工程并运行：

   ```bash
   open AppleTVRemote.xcodeproj
   ```

   在 Xcode 里选择 Scheme `AppleTVRemote`，⌘R 运行。应用只出现在菜单栏
   （无 Dock 图标），点菜单栏的遥控器图标即可。

3. 首次使用：

   - 打开菜单栏遥控器 → 齿轮（设置）
   - 点击“扫描设备”，选中你的 Apple TV
   - 点击“配对”，Apple TV 屏幕会显示 PIN 码，输入后确认
   - 点击“连接”，之后启动应用会自动重连

## 开发时用工程内的虚拟环境

默认情况下应用使用 `~/Library/Application Support/AppleTVRemote/venv` 里的
Python。开发时也可以指向项目自己的环境（比如不想跑 setup.sh）：

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
ATV_BRIDGE_PYTHON="$PWD/.venv/bin/python3" xcodebuild -scheme AppleTVRemote -derivedDataPath DerivedData build
```

或在 Xcode 的 Scheme 环境变量里设置 `ATV_BRIDGE_PYTHON`。

## 常见问题

### 扫描不到 Apple TV

- 确认 Mac 和 Apple TV 在同一个局域网（同一路由器/VLAN）。
- Apple TV 需要处于开机状态（休眠也可以被发现）。
- 公司网络或访客网络可能禁止 mDNS 组播。

### 连接失败 / 配对失败

- 在设置 → 后端 里查看日志，通常有具体原因。
- 重新配对：先在设置里“断开”，再对同一设备“配对”。
- 如果之前配对过但凭据失效，删掉
  `~/Library/Application Support/AppleTVRemote/pyatv.json` 后重新配对。

### 音量按钮无效

Apple TV 的音量通常由 HDMI-CEC/红外控制接收器完成，pyatv 对部分设备/协议
不提供音量控制。方向键、确认、菜单、播放暂停等核心按键不受影响。

### 唤醒

Apple TV 处于睡眠时可能无法连接。可以先点“连接”触发唤醒（Companion 协议会
尝试唤醒），或在设置里再次扫描后连接。

## 隐私

配对凭据（相当于这把 Mac 在 Apple TV 上的“钥匙”）只保存在本机
`~/Library/Application Support/AppleTVRemote/pyatv.json`，不会上传到任何地方。
