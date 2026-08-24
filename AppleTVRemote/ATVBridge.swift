import Foundation
import Combine
import Darwin
import AppleTVControl

enum BridgeError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}

/// 应用与原生 AppleTVControl 协议栈之间的桥接层。
///
/// 替代原先内嵌 Python + pyatv 的方案:直接在进程内完成设备发现、
/// 配对、连接(Companion 控制 + MRP 元数据)与控制命令,不再启动子进程。
final class ATVBridge: ObservableObject {
    static weak var shared: ATVBridge?

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var devices: [ATVDevice] = []
    @Published private(set) var currentDevice: ATVDevice?
    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var apps: [RemoteApp] = []
    @Published private(set) var pairingAwaitingPin = false
    @Published private(set) var isScanning = false
    @Published private(set) var isPairing = false
    @Published var lastError: String?

    private let defaults = UserDefaults.standard
    private let credentialsStore: CredentialsStore

    // 发现
    private let discovery = DeviceDiscovery()
    private let discoveryLock = NSLock()
    private var discoveredDevices: [String: DiscoveredDevice] = [:]

    // 连接
    private let connectionLock = NSLock()
    private var companionAPI: CompanionAPI?
    private var mrpAPI: MRPAPI?

    // 配对
    private var pairingProcedure: CompanionPairSetupProcedure?
    private var pairingConnection: TCPCompanionConnection?
    private var pairingDeviceID: String?

    private var statusTimer: Timer?

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppleTVRemote", isDirectory: true)
        credentialsStore = CredentialsStore(fileURL: appSupport.appendingPathComponent("credentials.json"))

        discovery.onDevicesUpdated = { [weak self] devices in
            self?.handleDevicesUpdated(devices)
        }

        ATVBridge.shared = self
    }

    // MARK: - 设备发现

    private func handleDevicesUpdated(_ discovered: [DiscoveredDevice]) {
        discoveryLock.lock()
        discoveredDevices = Dictionary(uniqueKeysWithValues: discovered.map { ($0.identifier, $0) })
        discoveryLock.unlock()

        let appDevices = discovered.map(appDevice(from:))
        DispatchQueue.main.async { self.devices = appDevices }
    }

    private func appDevice(from device: DiscoveredDevice) -> ATVDevice {
        var services: [String] = []
        if device.isCompanionSupported { services.append("Companion") }
        if device.isMRPSupported { services.append("MRP") }
        return ATVDevice(
            identifier: device.identifier,
            name: device.name,
            address: device.host,
            model: device.model,
            services: services
        )
    }

    func scanDevices() async {
        DispatchQueue.main.async { self.isScanning = true }
        discovery.start()
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        discovery.stop()
        DispatchQueue.main.async { self.isScanning = false }
    }

    /// 拿到某台设备的完整信息(host/端口)。缓存未命中时先扫描一次。
    private func resolveDevice(identifier: String) async throws -> DiscoveredDevice {
        if let cached = cachedDevice(identifier) { return cached }
        discovery.start()
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        discovery.stop()
        guard let found = cachedDevice(identifier) else {
            throw BridgeError.message("找不到设备 \(identifier)，请先在设置中扫描并连接")
        }
        return found
    }

    private func cachedDevice(_ identifier: String) -> DiscoveredDevice? {
        discoveryLock.lock()
        defer { discoveryLock.unlock() }
        return discoveredDevices[identifier]
    }

    // MARK: - 配对

    func pairBegin(device: ATVDevice) async {
        DispatchQueue.main.async { self.isPairing = true }
        do {
            let discovered = try await resolveDevice(identifier: device.identifier)
            guard let port = discovered.companionPort else {
                throw BridgeError.message("设备不支持 Companion 协议，无法配对")
            }

            let connection = TCPCompanionConnection(host: discovered.host, port: UInt16(port))
            let srp = SRPAuthHandler()
            let protocolLayer = CompanionProtocol(connection: connection, srp: srp)
            let procedure = CompanionPairSetupProcedure(protocolLayer, srp)

            try await procedure.startPairing()

            pairingProcedure = procedure
            pairingConnection = connection
            pairingDeviceID = discovered.identifier
            DispatchQueue.main.async { self.pairingAwaitingPin = true }
        } catch {
            DispatchQueue.main.async { self.isPairing = false }
            setError(error)
        }
    }

    func pairFinish(pin: String) async {
        do {
            guard let procedure = pairingProcedure,
                  let deviceID = pairingDeviceID else {
                throw BridgeError.message("当前没有进行中的配对流程")
            }
            let credentials = try await procedure.finishPairing(pin: pin, displayName: "MacBook Remote")
            credentialsStore.save(credentials, for: deviceID)

            pairingConnection?.close()
            pairingProcedure = nil
            pairingConnection = nil
            pairingDeviceID = nil

            DispatchQueue.main.async {
                self.pairingAwaitingPin = false
                self.isPairing = false
            }
        } catch {
            pairingConnection?.close()
            pairingProcedure = nil
            pairingConnection = nil
            pairingDeviceID = nil
            DispatchQueue.main.async {
                self.pairingAwaitingPin = false
                self.isPairing = false
            }
            setError(error)
        }
    }

    // MARK: - 连接

    func connect(device: ATVDevice) async {
        await connect(identifier: device.identifier)
    }

    func connect(identifier: String) async {
        DispatchQueue.main.async { self.connectionState = .connecting }
        do {
            try await performConnect(identifier: identifier)
        } catch {
            DispatchQueue.main.async { self.connectionState = .failed(error.localizedDescription) }
        }
    }

    private func performConnect(identifier: String) async throws {
        let discovered = try await resolveDevice(identifier: identifier)

        guard let credentials = credentialsStore.credentials(for: identifier) else {
            throw BridgeError.message("尚未配对：请先在设置中对该设备执行“配对”。")
        }
        guard let companionPort = discovered.companionPort else {
            throw BridgeError.message("设备不支持 Companion 协议，无法控制")
        }

        let clientID = String(data: credentials.clientId, encoding: .utf8) ?? ""

        // Companion:控制通道(按键/媒体/电源/应用)。
        let companionConnection = TCPCompanionConnection(host: discovered.host, port: UInt16(companionPort))
        let companionSRP = SRPAuthHandler(pairingId: credentials.clientId)
        let companionProtocol = CompanionProtocol(connection: companionConnection, srp: companionSRP)
        let companionInfo = CompanionDeviceInfo(name: "MacBook Remote", model: "Mac", identifier: clientID)
        let companion = CompanionAPI(
            protocolLayer: companionProtocol, credentials: credentials, deviceInfo: companionInfo)
        try await companion.connect()

        // MRP:元数据通道(可选,失败不阻断控制)。
        var mrp: MRPAPI?
        if let mrpPort = discovered.mrpPort {
            let mrpConnection = MRPTCPConnection(host: discovered.host, port: UInt16(mrpPort))
            let mrpSRP = SRPAuthHandler(pairingId: credentials.clientId)
            let mrpProtocol = MRPProtocol(connection: mrpConnection, srp: mrpSRP)
            let mrpInfo = MRPDeviceInfo(
                name: "MacBook Remote", identifier: clientID, osBuild: osBuild, modelName: "Mac")
            let api = MRPAPI(protocolLayer: mrpProtocol)
            do {
                try await api.connect(credentials: credentials, deviceInfo: mrpInfo)
                mrp = api
            } catch {
                api.disconnect()
            }
        }

        connectionLock.lock()
        self.companionAPI = companion
        self.mrpAPI = mrp
        connectionLock.unlock()

        DispatchQueue.main.async {
            self.currentDevice = self.appDevice(from: discovered)
            self.connectionState = .connected
            self.defaults.set(identifier, forKey: "lastDeviceIdentifier")
            self.lastError = nil
        }
        startStatusTimer()
        await pollStatus()
    }

    func disconnect() async {
        stopStatusTimer()
        connectionLock.lock()
        let companion = companionAPI
        let mrp = mrpAPI
        companionAPI = nil
        mrpAPI = nil
        connectionLock.unlock()

        try? await companion?.disconnect()
        mrp?.disconnect()

        DispatchQueue.main.async {
            self.connectionState = .disconnected
            self.currentDevice = nil
            self.nowPlaying = nil
            self.apps = []
            self.defaults.removeObject(forKey: "lastDeviceIdentifier")
        }
    }

    // MARK: - 控制命令

    func sendKey(_ key: RemoteKey) async {
        guard let companion = currentCompanion() else {
            setError(BridgeError.message("尚未连接到 Apple TV，请先在设置中连接"))
            return
        }
        do {
            try await performKey(key, on: companion)
        } catch {
            setError(error)
        }
    }

    private func performKey(_ key: RemoteKey, on api: CompanionAPI) async throws {
        switch key {
        case .up: try await api.press(.up)
        case .down: try await api.press(.down)
        case .left: try await api.press(.left)
        case .right: try await api.press(.right)
        case .select: try await api.press(.select)
        case .menu: try await api.press(.menu)
        case .home: try await api.press(.home)
        case .playPause: try await api.press(.playPause)
        case .next: _ = try await api.mediaCommand(.nextTrack)
        case .previous: _ = try await api.mediaCommand(.previousTrack)
        case .volumeUp: try await api.press(.volumeUp)
        case .volumeDown: try await api.press(.volumeDown)
        case .skipForward: try await api.skip(seconds: 10)
        case .skipBackward: try await api.skip(seconds: -10)
        case .topMenu: try await api.press(.menu)
        }
    }

    func power(_ action: String) async {
        guard let companion = currentCompanion() else {
            setError(BridgeError.message("尚未连接到 Apple TV，请先在设置中连接"))
            return
        }
        do {
            switch action {
            case "on":
                try await companion.turnOn()
            case "off":
                try await companion.turnOff()
            default:
                let state = try? await companion.fetchAttentionState()
                if state == .awake || state == .idle {
                    try await companion.turnOff()
                } else {
                    try await companion.turnOn()
                }
            }
            await pollStatus()
        } catch {
            setError(error)
        }
    }

    func volume(_ action: String) async {
        guard let companion = currentCompanion() else {
            setError(BridgeError.message("尚未连接到 Apple TV，请先在设置中连接"))
            return
        }
        do {
            if action == "up" {
                try await companion.press(.volumeUp)
            } else {
                try await companion.press(.volumeDown)
            }
        } catch {
            setError(error)
        }
    }

    func loadApps() async {
        guard let companion = currentCompanion() else {
            setError(BridgeError.message("尚未连接到 Apple TV，请先在设置中连接"))
            return
        }
        do {
            let list = try await companion.appList()
            let found = list.map { RemoteApp(identifier: $0.key, name: $0.value) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async { self.apps = found }
        } catch {
            setError(error)
        }
    }

    func launchApp(_ identifier: String) async {
        guard let companion = currentCompanion() else {
            setError(BridgeError.message("尚未连接到 Apple TV，请先在设置中连接"))
            return
        }
        do {
            try await companion.launchApp(identifier)
        } catch {
            setError(error)
        }
    }

    // MARK: - 状态

    func pollStatus() async {
        let mrp = currentMRP()
        let companion = currentCompanion()
        guard mrp != nil || companion != nil else { return }

        let np = mrp?.nowPlaying()
        let artwork = mrp?.artwork()

        var powerState: String?
        if let companion {
            powerState = (try? await companion.fetchAttentionState()).map(powerStateString)
        }

        let playing = NowPlaying(
            title: np?.title,
            artist: np?.artist,
            album: np?.album,
            mediaType: np?.mediaType,
            deviceState: np.map { playbackStateString($0.playbackState) } ?? nil,
            position: np?.position,
            totalTime: np?.duration,
            artwork: artwork,
            powerState: powerState
        )
        DispatchQueue.main.async { self.nowPlaying = playing }
    }

    func autoConnectIfNeeded() {
        guard let identifier = defaults.string(forKey: "lastDeviceIdentifier") else { return }
        Task { await connect(identifier: identifier) }
    }

    private func powerStateString(_ state: SystemStatus) -> String {
        switch state {
        case .awake, .idle: "On"
        case .asleep, .screensaver: "Off"
        case .unknown: "Unknown"
        }
    }

    private func playbackStateString(_ state: PlaybackState.Enum) -> String? {
        switch state {
        case .playing: "Playing"
        case .paused: "Paused"
        case .stopped: "Stopped"
        case .interrupted: "Interrupted"
        case .seeking: "Seeking"
        default: nil
        }
    }

    // MARK: - 生命周期

    func stop() {
        discovery.stop()
        stopStatusTimer()
        connectionLock.lock()
        let companion = companionAPI
        let mrp = mrpAPI
        companionAPI = nil
        mrpAPI = nil
        connectionLock.unlock()

        if companion != nil || mrp != nil {
            Task {
                try? await companion?.disconnect()
                mrp?.disconnect()
            }
        }
    }

    private func startStatusTimer() {
        stopStatusTimer()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.pollStatus() }
        }
    }

    private func stopStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    // MARK: - 工具

    private func currentCompanion() -> CompanionAPI? {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        return companionAPI
    }

    private func currentMRP() -> MRPAPI? {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        return mrpAPI
    }

    private func setError(_ error: Error) {
        DispatchQueue.main.async { self.lastError = error.localizedDescription }
    }

    /// 当前 macOS 系统构建号(如 "23A344"),用于 MRP DeviceInfo。
    private var osBuild: String {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("kern.osversion", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}
