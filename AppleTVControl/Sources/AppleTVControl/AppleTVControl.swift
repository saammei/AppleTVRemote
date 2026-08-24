// AppleTVControl — 原生 Swift 实现的 Apple TV 控制协议栈。
//
// 目标:替代内嵌 Python + pyatv,把 DMG 从 ~40MB 压到 1-3MB。
//
// 模块划分:
//   - Discovery:     Bonjour (NetService) 设备发现
//   - Crypto:        SRP-6a / TLV8 / ChaCha20-Poly1305 封装
//   - Serialization: opack 编解码
//   - Companion:     Companion 配对(Pair-Setup/Pair-Verify)与加密通道
//   - MRP:           MediaRemote 控制消息(按键/状态/应用/文本)

public enum AppleTVControl {
    /// 库版本,随发布递增。
    public static let version = "0.1.0"
}
