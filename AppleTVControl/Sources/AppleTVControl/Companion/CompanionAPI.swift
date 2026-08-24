// Companion 控制层:在加密通道之上实现按键/媒体/电源/应用/文本等命令。
// 对应 pyatv 的 pyatv/protocols/companion/api.py 的 CompanionAPI。
//
// 命令消息结构(OPACK):
//   {"_i": <命令名字符串>, "_t": <2=请求/1=事件/3=响应>, "_c": <命令内容>}
// 经 exchange_opack(FrameType.E_OPACK) 发送并等待 _x 匹配的响应。

import Foundation

// MARK: - 命令常量

/// HID 按键命令值(对应 pyatv api.py 的 HidCommand)。
public enum HidCommand: Int64 {
    case up = 1
    case down = 2
    case left = 3
    case right = 4
    case menu = 5
    case select = 6
    case home = 7
    case volumeUp = 8
    case volumeDown = 9
    case siri = 10
    case screensaver = 11
    case sleep = 12
    case wake = 13
    case playPause = 14
    case channelIncrement = 15
    case channelDecrement = 16
    case guide = 17
    case pageUp = 18
    case pageDown = 19
}

/// 媒体控制命令值(对应 pyatv api.py 的 MediaControlCommand)。
public enum MediaControlCommand: Int64 {
    case play = 1
    case pause = 2
    case nextTrack = 3
    case previousTrack = 4
    case getVolume = 5
    case setVolume = 6
    case skipBy = 7
    case fastForwardBegin = 8
    case fastForwardEnd = 9
    case rewindBegin = 10
    case rewindEnd = 11
    case getCaptionSettings = 12
    case setCaptionSettings = 13
}

/// 设备系统状态(对应 pyatv api.py 的 SystemStatus)。
public enum SystemStatus: Int64 {
    case unknown = 0
    case asleep = 1
    case screensaver = 2
    case awake = 3
    case idle = 4
}

/// 控制器(本机)的标识信息,用于 system_info 命令。
public struct CompanionDeviceInfo {
    /// 控制器名称(如 "MacBook Remote")。
    public let name: String
    /// 控制器型号(如 "Mac")。
    public let model: String
    /// 稳定标识(远程 profile id / device id,小写无分隔符)。用于 system_info 的 _i / _pubID。
    public let identifier: String

    public init(name: String, model: String, identifier: String) {
        self.name = name
        self.model = model
        self.identifier = identifier
    }
}

// MARK: - CompanionAPI

public final class CompanionAPI {
    private let protocolLayer: CompanionProtocol
    private let credentials: HapCredentials
    private let deviceInfo: CompanionDeviceInfo

    /// 会话 ID(remote_sid << 32 | local_sid),用于 _sessionStop。
    private var sid: UInt64 = 0
    private var subscribedEvents: Set<String> = []
    /// 文本输入会话 UUID(从 _tiStart 的 _tiD 解析),用于 _tiC 操作。
    private var textSessionUUID: Data?

    public init(
        protocolLayer: CompanionProtocol,
        credentials: HapCredentials,
        deviceInfo: CompanionDeviceInfo
    ) {
        self.protocolLayer = protocolLayer
        self.credentials = credentials
        self.deviceInfo = deviceInfo
    }

    // MARK: - 连接 / 断开

    /// 建立加密连接并完成会话初始化(系统信息 / 触控 / 会话 / 文本输入 / 事件订阅)。
    public func connect() async throws {
        try await protocolLayer.start(credentials: credentials)

        try await systemInfo()
        try await touchStart()
        try await sessionStart()
        try? await tvRCSessionStart()          // 旧设备可能不支持,忽略
        try? await textInputStart()            // 文本输入会话(connect 阶段不要求成功)
        try? subscribeEvent("_iMC")            // 媒体控制标志事件
    }

    public func disconnect() async throws {
        for event in subscribedEvents {
            try? unsubscribeEvent(event)
        }
        try? await sessionStop()
        protocolLayer.stop()
    }

    // MARK: - 底层命令收发

    private func sendCommand(
        _ identifier: String,
        _ content: [String: Any],
        messageType: CompanionMessageType = .request
    ) async throws -> [String: Any] {
        try await protocolLayer.exchangeOpack(
            .eOpack,
            ["_i": identifier, "_t": messageType.rawValue, "_c": content]
        )
    }

    private func sendEvent(_ identifier: String, _ content: [String: Any]) throws {
        // 事件不等待响应(pyatv 用 send_opack,不 exchange)。
        try protocolLayer.sendOpack(
            .eOpack,
            ["_i": identifier, "_t": CompanionMessageType.event.rawValue, "_c": content]
        )
    }

    /// 命令响应必须带 _c,否则视为协议错误(对应 pyatv 的检查)。
    private func content(of response: [String: Any]) throws -> [String: Any] {
        guard let content = response["_c"] as? [String: Any] else {
            throw CompanionError.protocolError("命令响应缺少 _c 字段")
        }
        return content
    }

    // MARK: - 会话命令

    private func systemInfo() async throws {
        _ = try await sendCommand("_systemInfo", [
            "_bf": 0,
            "_cf": 512,
            "_clFl": 128,
            // 非空 _i 让设备继续推送电源(TVSystemStatus)事件。
            "_i": deviceInfo.identifier,
            "_idsID": String(data: credentials.clientId, encoding: .utf8) ?? "",
            "_pubID": deviceInfo.identifier,
            "_sf": 256,
            "_sv": "170.18",
            "model": deviceInfo.model,
            "name": deviceInfo.name,
        ])
    }

    private func touchStart() async throws {
        _ = try await sendCommand("_touchStart", [
            "_height": 1000, "_tFl": 0, "_width": 1000,
        ])
    }

    private func sessionStart() async throws {
        let localSid = UInt32.random(in: 0...UInt32.max)
        let response = try await sendCommand("_sessionStart", [
            "_srvT": "com.apple.tvremoteservices", "_sid": Int64(localSid),
        ])
        let content = try content(of: response)
        guard let remoteSid = content["_sid"] as? Int64 else {
            throw CompanionError.protocolError("_sessionStart 响应缺少 _sid")
        }
        sid = (UInt64(remoteSid) << 32) | UInt64(localSid)
    }

    private func sessionStop() async throws {
        guard sid != 0 else { return }
        _ = try await sendCommand("_sessionStop", [
            "_srvT": "com.apple.tvremoteservices", "_sid": sid,
        ])
    }

    private func tvRCSessionStart() async throws {
        _ = try await sendCommand("TVRCSessionStart", ["ProtocolVersionKey": "1.2"])
    }

    // MARK: - 事件订阅

    public func subscribeEvent(_ event: String) throws {
        guard !subscribedEvents.contains(event) else { return }
        try sendEvent("_interest", ["_regEvents": [event]])
        subscribedEvents.insert(event)
    }

    public func unsubscribeEvent(_ event: String) throws {
        guard subscribedEvents.contains(event) else { return }
        try sendEvent("_interest", ["_deregEvents": [event]])
        subscribedEvents.remove(event)
    }

    // MARK: - 按键(HID)

    /// 发送一次 HID 按下/抬起。`down` 为 true 表示按下,false 表示抬起。
    public func hidCommand(down: Bool, command: HidCommand) async throws {
        _ = try await sendCommand("_hidC", [
            "_hBtS": down ? 1 : 2, "_hidC": command.rawValue,
        ])
    }

    /// 单击(按下后立即抬起),对应 pyatv 的 SingleTap。
    public func press(_ command: HidCommand) async throws {
        try await hidCommand(down: true, command: command)
        try await hidCommand(down: false, command: command)
    }

    // MARK: - 媒体控制

    public func mediaCommand(
        _ command: MediaControlCommand, args: [String: Any] = [:]
    ) async throws -> [String: Any] {
        var content: [String: Any] = ["_mcc": command.rawValue]
        for (key, value) in args { content[key] = value }
        return try await sendCommand("_mcc", content)
    }

    /// 设置音量(0.0-1.0)。
    public func setVolume(_ level: Double) async throws {
        _ = try await mediaCommand(.setVolume, args: ["_vol": level])
    }

    /// 快进/快退 `seconds` 秒(正数前进,负数后退)。
    public func skip(seconds: Double) async throws {
        _ = try await mediaCommand(.skipBy, args: ["_skpS": seconds])
    }

    // MARK: - 电源

    /// 查询设备当前系统状态。
    public func fetchAttentionState() async throws -> SystemStatus {
        let response = try await sendCommand("FetchAttentionState", [:])
        let content = try content(of: response)
        guard let state = content["state"] as? Int64 else {
            throw CompanionError.protocolError("FetchAttentionState 响应缺少 state")
        }
        return SystemStatus(rawValue: state) ?? .unknown
    }

    public func turnOn() async throws {
        try await hidCommand(down: false, command: .wake)
    }

    public func turnOff() async throws {
        try await hidCommand(down: false, command: .sleep)
    }

    // MARK: - 应用

    /// 获取可启动应用列表,返回 [bundle_id: name]。
    public func appList() async throws -> [String: String] {
        let response = try await sendCommand("FetchLaunchableApplicationsEvent", [:])
        let content = try content(of: response)
        var result: [String: String] = [:]
        for (bundleId, value) in content {
            if let name = value as? String { result[bundleId] = name }
        }
        return result
    }

    /// 启动应用(bundle ID)。
    public func launchApp(_ bundleId: String) async throws {
        _ = try await sendCommand("_launchApp", ["_bundleID": bundleId])
    }

    // MARK: - 文本输入(RTI)

    /// 启动文本输入会话并解析 _tiD 里的 session UUID。
    private func textInputStart() async throws {
        let response = try await sendCommand("_tiStart", [:])
        if let content = response["_c"] as? [String: Any],
           let tiData = content["_tiD"] as? Data {
            let props = RTITextInput.readArchiveProperties(tiData, paths: [["sessionUUID"]])
            textSessionUUID = props.first as? Data
        }
    }

    private func textInputStop() async throws {
        _ = try await sendCommand("_tiStop", [:])
    }

    /// 发送一次文本输入。`clearPreviousInput` 为 true 时先清空现有文本(对应 text_set/text_clear)。
    public func textInputCommand(_ text: String, clearPreviousInput: Bool = false) async throws {
        // 重启会话以拿到最新的 _tiD(与 pyatv text_input_command 一致)。
        try await textInputStop()
        try await textInputStart()
        guard let sessionUUID = textSessionUUID else { return }

        if clearPreviousInput {
            try sendEvent("_tiC", ["_tiV": 1, "_tiD": RTITextInput.clearTextPayload(sessionUUID: sessionUUID)])
        }
        if !text.isEmpty {
            try sendEvent("_tiC", ["_tiV": 1, "_tiD": RTITextInput.inputTextPayload(sessionUUID: sessionUUID, text: text)])
        }
    }

    /// 在光标处追加文本(对应 keyboard.text_append)。
    public func textAppend(_ text: String) async throws {
        try await textInputCommand(text, clearPreviousInput: false)
    }

    /// 用文本整体替换输入框内容(对应 keyboard.text_set)。
    public func textSet(_ text: String) async throws {
        try await textInputCommand(text, clearPreviousInput: true)
    }

    /// 清空输入框(对应 keyboard.text_clear)。
    public func textClear() async throws {
        try await textInputCommand("", clearPreviousInput: true)
    }
}
