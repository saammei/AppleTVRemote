# 开发指南

## 一、环境要求

- macOS 14+（部署目标 14.0），Apple Silicon（arm64）。
- Swift 5.9+ / Xcode 16+（`objectVersion 77`，工程用 `PBXFileSystemSynchronizedRootGroup`）。
- 依赖由 SPM 自动解析：`swift-protobuf`、`BigInt`（首次构建需联网拉取）。

> ⚠️ 本机当前只有 **CommandLineTools、没有完整 Xcode**，`xcodebuild` 不可用。
> 见下方「无 Xcode 时的手工打包」。

## 二、构建与测试

### 协议栈自测（无 XCTest，自定义断言框架）

```bash
cd AppleTVControl
swift run AppleTVControlTests
# 通过时打印 "✅ All tests passed"
```

测试入口是 `Sources/AppleTVControlTests/main.swift`，逐个调用
`runCompanionTests() / runMRPTests() / runCryptoTests() / runDiscoveryTests() /
runBinaryPlistTests() / runOPACKTests() / runCredentialsStoreTests()` 等。

### 构建应用（需完整 Xcode）

```bash
xcodebuild -project AppleTVRemote.xcodeproj -scheme AppleTVRemote \
  -configuration Release -derivedDataPath DerivedData \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY="-" build
```

或直接 `open AppleTVRemote.xcodeproj` 后 ⌘R。产物在
`DerivedData/Build/Products/Release/AppleTVRemote.app`。

### 无 Xcode 时的手工打包（本机已验证可用）

思路：用 Swift 工具链把 5 个应用源文件 + 本地包编译成可执行文件，再手工组装 `.app`。

```bash
# 1. 建临时 SPM 可执行包（依赖本地 AppleTVControl）
mkdir -p /tmp/atv-app-build/Sources/ATVApp
cp AppleTVRemote/AppleTVRemote/*.swift /tmp/atv-app-build/Sources/ATVApp/
# Package.swift: executableTarget(name:"ATVApp", 依赖 .product("AppleTVControl"), path 指向本仓库 AppleTVControl)

# 2. 编译
cd /tmp/atv-app-build && swift build -c release
#    → .build/release/ATVApp（约 9MB，未 strip）

# 3. 组装 .app
mkdir -p AppleTVRemote.app/Contents/{MacOS,Resources}
cp .build/release/ATVApp AppleTVRemote.app/Contents/MacOS/AppleTVRemote
# 写 Info.plist（把 $(EXECUTABLE_NAME) 等变量替换成真实值，bundle id = com.meishaoming.AppleTVRemote）
# 图标：iconutil -c icns AppIcon.iconset -o Contents/Resources/AppIcon.icns
#   （iconset 的 PNG 直接取自 Assets.xcassets/AppIcon.appiconset/，命名已匹配）

# 4. 签名 + 安装 + 运行
codesign --force --deep --sign - AppleTVRemote.app
cp -R AppleTVRemote.app /Applications/ && open /Applications/AppleTVRemote.app
```

注意：`actool`（Xcode 专用）不可用，所以不能用 asset catalog 编译，只能用 `iconutil`
从 PNG 手工转 `.icns`。

## 三、代码结构速查

```
AppleTVRemote/
├── AppleTVRemoteApp.swift   @main 入口 + AppDelegate（单实例检测）
├── ATVBridge.swift          桥接层（发现/配对/连接/控制/状态，唯一 import AppleTVControl）
├── Models.swift             ATVDevice / NowPlaying / RemoteApp / ConnectionState / RemoteKey
├── RemoteView.swift         主面板 UI（按钮 + 键盘捕获 + 正在播放）
└── SettingsView.swift       设置（扫描/配对/连接）
AppleTVControl/
├── Package.swift            产品 AppleTVControl（library）+ AppleTVControlTests（executable）
└── Sources/AppleTVControl/  Discovery / Companion / MRP / Crypto / Storage
```

## 四、常见坑

- **工程用文件系统同步**：`AppleTVRemote.xcodeproj` 的 target 用
  `PBXFileSystemSynchronizedRootGroup`，新增/删除 `AppleTVRemote/` 下的 `.swift` 文件
  **无需改 pbxproj**（自动发现）。但改 `Info.plist`、依赖、build 设置仍需改 pbxproj。
- **macOS 的 BSD sed 不支持 `\b`**：批量替换要用 `Edit` 工具或 `sed` 的 `[[:<:]]`/`[[:>:]]`。
- **`ATVDevice` 命名冲突**：包内设备类型叫 `DiscoveredDevice`，应用层类型叫 `ATVDevice`
  （两者不要混用，`ATVBridge.appDevice(from:)` 负责转换）。
- **本地网络权限**：首次扫描需要用户授权「本地网络」，`Info.plist` 已配
  `NSLocalNetworkUsageDescription`。
- **凭据位置**：`~/Library/Application Support/AppleTVRemote/credentials.json`。
- **音量按钮**：部分设备/协议不提供音量控制（HDMI-CEC/红外），属正常现象，核心按键不受影响。
