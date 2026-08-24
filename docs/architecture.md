# 架构设计

## 一、总体结构

```
┌───────────────────────────────────────────────┐
│  AppleTVRemote.app（SwiftUI 菜单栏应用）        │
│  RemoteView / SettingsView / Models            │
│  ATVBridge（桥接层，ObservableObject）          │
└───────────────┬───────────────────────────────┘
                │ 直接调用（进程内，无子进程）
┌───────────────▼───────────────────────────────┐
│  AppleTVControl（本地 Swift Package）           │
│  Discovery / Companion / MRP / Crypto / Storage│
└───────────────┬───────────────────────────────┘
                │ TCP / mDNS
                ▼
             Apple TV
```

核心设计：把原先「内嵌 Python 运行时 + pyatv 子进程」的方案，替换成**进程内原生 Swift
协议栈**。`ATVBridge` 不再启动子进程，而是直接调用 `AppleTVControl` 包的 API。发布包因此
从 ~40MB 降到 ~3.6MB。

## 二、AppleTVControl 包分层

```
Sources/AppleTVControl/
├── Discovery/      设备发现（Bonjour/NetService）
├── Companion/      Companion 协议（控制主通道）
├── MRP/            MRP 协议（正在播放元数据）
├── Crypto/         密码学原语（SRP / Curve25519 / ChaCha20 / HKDF / TLV8）
├── Storage/        凭据持久化
└── AppleTVControl.swift   (包入口/公共导出)
```

依赖（见 `Package.swift`）：`swift-protobuf`（from 1.38.0）、`BigInt`（from 5.3.0）。
平台 `macOS 14+`。

### 2.1 Discovery — 设备发现

- `DeviceDiscovery`：用 `NetServiceBrowser` 扫描两种 Bonjour 服务——
  `_mediaremotetv._tcp`（MRP）与 `_companion-link._tcp`（Companion），回调
  `onDevicesUpdated: (([DiscoveredDevice]) -> Void)?`。
- `DeviceAggregator`：把同一台设备（按 `identifier`）的 MRP + Companion 两个服务聚合成一个。
- `DiscoveredDevice`（对外核心类型）：

  ```swift
  public struct DiscoveredDevice {
      let identifier: String          // 设备唯一 ID（来自 TXT 记录）
      let name: String
      let host: String
      let model: String
      let companionPort: Int?         // nil = 不支持 Companion
      let mrpPort: Int?               // nil = 不支持 MRP
      let txt: [String: String]
      var isCompanionSupported: Bool  // companionPort != nil
      var isMRPSupported: Bool        // mrpPort != nil
  }
  ```

### 2.2 Companion — 控制主通道（按键/媒体/电源/应用/文本）

技术栈：TCP（`Network.framework` 的 `NWConnection`）→ 4 字节帧头 `[FrameType(1) + len(3, 大端)]`
→ OPACK 编码 → 加密。

- **配对**（首次，Apple TV 显示 4 位 PIN）：
  `CompanionPairSetupProcedure`（SRP-6a Pair-Setup）→ 拿 `HapCredentials`。
- **验证**（每次连接）：SRP + Curve25519（Pair-Verify）→ 协商出会话密钥。
- **加密**：`ChaCha20-Poly1305`（`CryptoKit`）。
- **连接层**：`TCPCompanionConnection`（`Connection.swift` 定义抽象接口）、
  `CompanionProtocol`（帧解析 + 命令分发）、`SRPAuthHandler`。
- **API 层** `CompanionAPI`（对应用暴露，核心方法）：

  | 方法 | 作用 |
  |---|---|
  | `connect() / disconnect()` | 建立/断开连接 |
  | `press(_ command: HidCommand)` | 按键 |
  | `mediaCommand(_: MediaControlCommand)` | 媒体命令（下一首/上一首…） |
  | `skip(seconds:)` | 快进/快退 |
  | `setVolume(_:)` | 设音量 |
  | `turnOn() / turnOff()` | 电源 |
  | `fetchAttentionState() -> SystemStatus` | 电源/屏保状态 |
  | `appList() -> [String: String]` / `launchApp(_:)` | 应用列表 / 启动应用 |
  | `textSet / textAppend / textClear` | 文本输入（搜索框） |

  枚举值：`HidCommand`（up/down/left/right/menu/select/home/volumeUp/volumeDown/siri/
  screensaver/sleep/wake/playPause/channel±/guide/page±）、`MediaControlCommand`
  （play/pause/nextTrack/previousTrack/skipBy/fastForward…）、`SystemStatus`
  （unknown=0/asleep=1/screensaver=2/awake=3/idle=4）。

### 2.3 MRP — 正在播放元数据（可选通道）

技术栈：TCP → **varint(LEB128) 长度前缀** → protobuf。MRP 用的是 protobuf **extension
fields**，故需要 `SimpleExtensionMap` 注册；消息加密走 `MRPCipher`（8 字节计数器 nonce）。

- 连接：`MRPTCPConnection` + `MRPProtocol`（握手 `MRPDeviceInfo`，含 `osBuild`）。
- API：`MRPAPI`，对外 `nowPlaying() -> MRPNowPlaying`、`artwork() -> Data?`。
- `MRPNowPlaying`：title / artist / album / mediaType / playbackState / position / duration。
- **`MRP/Generated/*.pb.swift`（77 个文件）是生成的，不要手改**。头部注释标了来源
  `Source: pyatv/protocols/mrp/protobuf/*.proto`——proto 源文件不在本仓库，来自 pyatv。
  如需改 MRP 消息：从 pyatv 取 `.proto`，用 `protoc` + swift-protobuf 生成器重新生成。

### 2.4 Crypto / Storage

- `Crypto/`：`SRP`（SRP-6a）、`ChaCha20`、`HKDF`、`TLV8`、`Credentials`（`HapCredentials`）。
- `HapCredentials`：`ltpk / ltsk / atvId / clientId`（都是 `Data`），`detailString` 序列化 /
  `parse` 反序列化。
- `Storage/CredentialsStore`：`[String: HapCredentials]`（按设备 identifier）持久化为 JSON
  `{ "<identifier>": "<detailString>" }`。API：`load() / credentials(for:) / save(_:for:) /
  remove(identifier:)`。

## 三、前端接入（ATVBridge）

`AppleTVRemote/ATVBridge.swift` 是应用与包的唯一桥接层（`ObservableObject` 单例）。

- **发现**：`DeviceDiscovery.onDevicesUpdated` → 转成应用自己的 `ATVDevice` 列表。
- **配对**：`pairBegin`（`startPairing` 触发电视显示 PIN）→ `pairFinish`（`finishPairing`
  拿凭据 → `credentialsStore.save`）。
- **连接**：`performConnect` 依次建立 Companion（必需）+ MRP（可选，`do/catch` 包裹，失败
  不阻断控制）。凭据存于 `~/Library/Application Support/AppleTVRemote/credentials.json`。
- **控制**：`performKey` 做应用按键 → `HidCommand` 映射（next/previous 走
  `mediaCommand`，skipForward/Backward 走 `skip(seconds: ±10)`，topMenu 复用 `menu`）。
- **状态**：`pollStatus`（5 秒定时器）合并 MRP 元数据 + Companion 电源状态 → `NowPlaying`。
- **自动重连**：`autoConnectIfNeeded` 读 `UserDefaults` 的 `lastDeviceIdentifier`。

## 四、协议参考

本实现对 pyatv 的逆向/对齐（文件头注释多处标注「对应 pyatv …」）。协议细节参考
[pyatv](https://github.com/postlund/pyatv) 源码 `pyatv/protocols/companion/` 与
`pyatv/protocols/mrp/`。

> 注意：**不支持 AirPlay 音频**。功能范围 = 遥控按钮 + 正在播放 + 应用启动 + 文本输入。
