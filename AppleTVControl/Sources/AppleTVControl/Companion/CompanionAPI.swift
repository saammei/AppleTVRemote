// Companion control layer: implements key press/media/power/apps/text commands on top of the
// encrypted channel.
// Corresponds to pyatv's CompanionAPI in pyatv/protocols/companion/api.py.
//
// Command message structure (OPACK):
//   {"_i": <command name string>, "_t": <2=request/1=event/3=response>, "_c": <command content>}
// Sent via exchange_opack (FrameType.E_OPACK), waiting for a response matching _x.

import Foundation

// MARK: - Command constants

/// HID key press command values (corresponding to HidCommand in pyatv api.py).
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

/// Media control command values (corresponding to MediaControlCommand in pyatv api.py).
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

/// Device system status (corresponding to SystemStatus in pyatv api.py).
public enum SystemStatus: Int64 {
    case unknown = 0
    case asleep = 1
    case screensaver = 2
    case awake = 3
    case idle = 4
}

/// Identity information for the controller (this device), used by the system_info command.
public struct CompanionDeviceInfo {
    /// Controller name (e.g. "MacBook Remote").
    public let name: String
    /// Controller model (e.g. "Mac").
    public let model: String
    /// Stable identifier (remote profile id / device id, lowercase without separators). Used for system_info's _i / _pubID.
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

    /// Session ID (remote_sid << 32 | local_sid), used for _sessionStop.
    private var sid: UInt64 = 0
    private var subscribedEvents: Set<String> = []
    /// Text input session UUID (parsed from _tiStart's _tiD), used for _tiC operations.
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

    /// Disconnect callback (forwarded from the protocol layer, triggered by the connection layer).
    public var onDisconnect: (() -> Void)? {
        get { protocolLayer.onDisconnect }
        set { protocolLayer.onDisconnect = newValue }
    }

    // MARK: - Connect / disconnect

    /// Establishes the encrypted connection and completes session initialization
    /// (system info / touch / session / text input / event subscription).
    public func connect() async throws {
        try await protocolLayer.start(credentials: credentials)

        try await systemInfo()
        try await touchStart()
        try await sessionStart()
        try? await tvRCSessionStart()          // older devices may not support it; ignore
        try? await textInputStart()            // text input session (not required to succeed at connect time)
        try? subscribeEvent("_iMC")            // media control flag events
    }

    public func disconnect() async throws {
        for event in subscribedEvents {
            try? unsubscribeEvent(event)
        }
        try? await sessionStop()
        protocolLayer.stop()
    }

    // MARK: - Low-level command send/receive

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
        // Events do not wait for a response (pyatv uses send_opack, not exchange).
        try protocolLayer.sendOpack(
            .eOpack,
            ["_i": identifier, "_t": CompanionMessageType.event.rawValue, "_c": content]
        )
    }

    /// Command responses must carry _c, otherwise it is treated as a protocol error (matching pyatv's check).
    private func content(of response: [String: Any]) throws -> [String: Any] {
        guard let content = response["_c"] as? [String: Any] else {
            throw CompanionError.protocolError("Command response is missing the _c field")
        }
        return content
    }

    // MARK: - Session commands

    private func systemInfo() async throws {
        _ = try await sendCommand("_systemInfo", [
            "_bf": 0,
            "_cf": 512,
            "_clFl": 128,
            // A non-empty _i makes the device keep pushing power (TVSystemStatus) events.
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
            throw CompanionError.protocolError("_sessionStart response is missing _sid")
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

    // MARK: - Event subscription

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

    // MARK: - Key press (HID)

    /// Sends one HID press/release. `down` true means pressed, false means released.
    public func hidCommand(down: Bool, command: HidCommand) async throws {
        _ = try await sendCommand("_hidC", [
            "_hBtS": down ? 1 : 2, "_hidC": command.rawValue,
        ])
    }

    /// Single tap (press then release immediately), corresponding to pyatv's SingleTap.
    public func press(_ command: HidCommand) async throws {
        try await hidCommand(down: true, command: command)
        try await hidCommand(down: false, command: command)
    }

    // MARK: - Media control

    public func mediaCommand(
        _ command: MediaControlCommand, args: [String: Any] = [:]
    ) async throws -> [String: Any] {
        var content: [String: Any] = ["_mcc": command.rawValue]
        for (key, value) in args { content[key] = value }
        return try await sendCommand("_mcc", content)
    }

    /// Sets the volume (0.0-1.0).
    public func setVolume(_ level: Double) async throws {
        _ = try await mediaCommand(.setVolume, args: ["_vol": level])
    }

    /// Fast forwards/rewinds by `seconds` seconds (positive forwards, negative backwards).
    public func skip(seconds: Double) async throws {
        _ = try await mediaCommand(.skipBy, args: ["_skpS": seconds])
    }

    // MARK: - Power

    /// Queries the device's current system status.
    public func fetchAttentionState() async throws -> SystemStatus {
        let response = try await sendCommand("FetchAttentionState", [:])
        let content = try content(of: response)
        guard let state = content["state"] as? Int64 else {
            throw CompanionError.protocolError("FetchAttentionState response is missing state")
        }
        return SystemStatus(rawValue: state) ?? .unknown
    }

    public func turnOn() async throws {
        try await hidCommand(down: false, command: .wake)
    }

    public func turnOff() async throws {
        try await hidCommand(down: false, command: .sleep)
    }

    // MARK: - Apps

    /// Gets the list of launchable apps, returning [bundle_id: name].
    public func appList() async throws -> [String: String] {
        let response = try await sendCommand("FetchLaunchableApplicationsEvent", [:])
        let content = try content(of: response)
        var result: [String: String] = [:]
        for (bundleId, value) in content {
            if let name = value as? String { result[bundleId] = name }
        }
        return result
    }

    /// Launches an app (bundle ID).
    public func launchApp(_ bundleId: String) async throws {
        _ = try await sendCommand("_launchApp", ["_bundleID": bundleId])
    }

    // MARK: - Text input (RTI)

    /// Starts a text input session and parses the session UUID from _tiD.
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

    /// Sends one text input. When `clearPreviousInput` is true, clears the existing text first (corresponds to text_set/text_clear).
    public func textInputCommand(_ text: String, clearPreviousInput: Bool = false) async throws {
        // Restart the session to get the latest _tiD (same as pyatv's text_input_command).
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

    /// Appends text at the cursor (corresponds to keyboard.text_append).
    public func textAppend(_ text: String) async throws {
        try await textInputCommand(text, clearPreviousInput: false)
    }

    /// Replaces the input field's content entirely with the given text (corresponds to keyboard.text_set).
    public func textSet(_ text: String) async throws {
        try await textInputCommand(text, clearPreviousInput: true)
    }

    /// Clears the input field (corresponds to keyboard.text_clear).
    public func textClear() async throws {
        try await textInputCommand("", clearPreviousInput: true)
    }
}
