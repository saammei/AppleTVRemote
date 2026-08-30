import Foundation
import Combine
import Darwin
import Dispatch
import os
import AppleTVControl

enum BridgeError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}

/// Bridge between the app and the native AppleTVControl protocol stack.
///
/// Replaces the previously embedded Python + pyatv approach: device discovery,
/// pairing, connection (Companion control + MRP metadata) and control commands
/// all run in-process, without spawning child processes.
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
    /// Scan-level errors (e.g. local network permission denied), shown separately from connect/pair errors.
    @Published private(set) var scanError: String?
    /// Whether local network permission was denied by the system (the user must enable it manually in System Settings).
    @Published private(set) var localNetworkDenied = false

    private let defaults = UserDefaults.standard
    private let credentialsStore: CredentialsStore
    private let logger = Logger(subsystem: "com.meishaoming.AppleTVRemote", category: "bridge")

    // Discovery
    private let discovery = DeviceDiscovery()
    private let discoveryLock = NSLock()
    private var discoveredDevices: [String: DiscoveredDevice] = [:]

    // Connection
    private let connectionLock = NSLock()
    private var companionAPI: CompanionAPI?
    private var mrpAPI: MRPAPI?

    // Pairing
    private var pairingProcedure: CompanionPairSetupProcedure?
    private var pairingConnection: TCPCompanionConnection?
    private var pairingDeviceID: String?

    private var statusTimer: DispatchSourceTimer?

    /// When the app list was last requested. Some firmware ignores FetchLaunchableApplicationsEvent,
    /// so the request only ends in a timeout; after a failure, throttle for 60 seconds to avoid
    /// repeating a doomed request every time the panel opens.
    /// Only accessed on the UI call path (loadApps); a race merely sends one extra request, harmless.
    private var lastAppsLoadAttempt = Date.distantPast
    /// Power poll interval: stays at 5 seconds on success; on failure (firmware ignores the
    /// command) backs off exponentially up to 60 seconds, avoiding a doomed timeout request
    /// every 5 seconds. As above, races are harmless.
    private var powerPollInterval: TimeInterval = 5
    private var lastPowerPoll = Date.distantPast

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppleTVRemote", isDirectory: true)
        credentialsStore = CredentialsStore(fileURL: appSupport.appendingPathComponent("credentials.json"))

        discovery.onDevicesUpdated = { [weak self] devices in
            self?.handleDevicesUpdated(devices)
        }
        discovery.onSearchError = { [weak self] error in
            self?.handleSearchError(error)
        }

        ATVBridge.shared = self
    }

    // MARK: - Device Discovery

    private func handleSearchError(_ error: DiscoveryError) {
        let message: String
        switch error {
        case .localNetworkDenied:
            message = "Local network permission denied: allow this app in System Settings → Privacy & Security → Local Network, then scan again."
        case .searchFailed(let code):
            message = "Scan failed (error code \(code)). Check your network and try again."
        }
        DispatchQueue.main.async {
            self.localNetworkDenied = (error == .localNetworkDenied)
            self.scanError = message
        }
    }

    private func handleDevicesUpdated(_ discovered: [DiscoveredDevice]) {
        discoveryLock.lock()
        discoveredDevices = Dictionary(uniqueKeysWithValues: discovered.map { ($0.identifier, $0) })
        discoveryLock.unlock()

        let appDevices = discovered.map(appDevice(from:))
        let names = appDevices.map { $0.name }
        Logger(subsystem: "com.meishaoming.AppleTVRemote", category: "discovery")
            .debug("Publishing device list \(names, privacy: .public)")
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
        DispatchQueue.main.async {
            self.isScanning = true
            self.scanError = nil
            self.localNetworkDenied = false
        }
        discovery.start()
        // 15-second window: leaves time for the first-time Local Network permission prompt;
        // after the user grants access, discovery keeps reporting results, so post-approval
        // results are not lost like they would be with a short window.
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        discovery.stop()
        DispatchQueue.main.async { self.isScanning = false }
    }

    /// Resolves full device info (host/ports). Scans once first if the cache misses.
    private func resolveDevice(identifier: String) async throws -> DiscoveredDevice {
        if let cached = cachedDevice(identifier) { return cached }
        discovery.start()
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        discovery.stop()
        guard let found = cachedDevice(identifier) else {
            // The legacy (Python) version stored MAC-form identifiers, while the new
            // version uses rpmrtid UUIDs; the two are incompatible. Clear the old value
            // so "device not found" is not reported on every launch.
            if defaults.string(forKey: "lastDeviceIdentifier") == identifier {
                defaults.removeObject(forKey: "lastDeviceIdentifier")
            }
            throw BridgeError.message("Device \(identifier) not found. Scan and connect from Settings first")
        }
        return found
    }

    private func cachedDevice(_ identifier: String) -> DiscoveredDevice? {
        discoveryLock.lock()
        defer { discoveryLock.unlock() }
        return discoveredDevices[identifier]
    }

    // MARK: - Pairing

    func pairBegin(device: ATVDevice) async {
        // Clean up any leftover pairing connection from a previous attempt (prevents TCP/SRP state leaks).
        pairingConnection?.close()
        pairingProcedure = nil
        pairingConnection = nil
        pairingDeviceID = nil
        DispatchQueue.main.async { self.isPairing = true }
        logger.debug("Starting pairing \(device.name, privacy: .public)")
        do {
            let discovered = try await resolveDevice(identifier: device.identifier)
            guard let port = discovered.companionPort else {
                throw BridgeError.message("This device does not support the Companion protocol, so it cannot be paired")
            }

            let connection = TCPCompanionConnection(host: discovered.host, port: UInt16(port))
            let srp = SRPAuthHandler()
            let protocolLayer = CompanionProtocol(connection: connection, srp: srp)
            let procedure = CompanionPairSetupProcedure(protocolLayer, srp)

            // The TCP connection must be established before sending pairing frames;
            // start(credentials: nil) only connects, without Pair-Verify.
            try await protocolLayer.start(credentials: nil)
            logger.debug("Pairing: TCP connected, sending Pair-Setup M1")
            try await procedure.startPairing()

            pairingProcedure = procedure
            pairingConnection = connection
            pairingDeviceID = discovered.identifier
            logger.debug("Pairing: device returned salt/public key, waiting for PIN")
            DispatchQueue.main.async { self.pairingAwaitingPin = true }
        } catch CompanionError.timeout {
            logger.error("Pairing: connection timed out (the TV may be in standby)")
            DispatchQueue.main.async { self.isPairing = false }
            setError(BridgeError.message("Timed out connecting to the Apple TV: make sure it is awake and on the same local network, then retry pairing."))
        } catch {
            logger.error("Pairing failed: \(String(describing: error), privacy: .public)")
            DispatchQueue.main.async { self.isPairing = false }
            setError(error)
        }
    }

    func pairFinish(pin: String) async {
        do {
            guard let procedure = pairingProcedure,
                  let deviceID = pairingDeviceID else {
                throw BridgeError.message("No pairing flow is currently in progress")
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

    func pairCancel() {
        pairingConnection?.close()
        pairingConnection = nil
        pairingProcedure = nil
        pairingDeviceID = nil
        DispatchQueue.main.async {
            self.pairingAwaitingPin = false
            self.isPairing = false
        }
    }

    // MARK: - Connection

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
            throw BridgeError.message("Not paired yet: run Pair for this device in Settings first.")
        }
        guard let companionPort = discovered.companionPort else {
            throw BridgeError.message("This device does not support the Companion protocol and cannot be controlled")
        }

        let clientID = String(data: credentials.clientId, encoding: .utf8) ?? ""

        // Companion: control channel (keys/media/power/apps).
        let companionConnection = TCPCompanionConnection(host: discovered.host, port: UInt16(companionPort))
        let companionSRP = SRPAuthHandler(pairingId: credentials.clientId)
        let companionProtocol = CompanionProtocol(connection: companionConnection, srp: companionSRP)
        let companionInfo = CompanionDeviceInfo(name: "MacBook Remote", model: "Mac", identifier: clientID)
        let companion = CompanionAPI(
            protocolLayer: companionProtocol, credentials: credentials, deviceInfo: companionInfo)
        companion.onDisconnect = { [weak self] in self?.handleDisconnect() }
        try await companion.connect()

        // MRP: metadata channel (optional; failure does not block control).
        var mrp: MRPAPI?
        if let mrpPort = discovered.mrpPort {
            let mrpConnection = MRPTCPConnection(host: discovered.host, port: UInt16(mrpPort))
            let mrpSRP = SRPAuthHandler(pairingId: credentials.clientId)
            let mrpProtocol = MRPProtocol(connection: mrpConnection, srp: mrpSRP)
            let mrpInfo = MRPDeviceInfo(
                name: "MacBook Remote", identifier: clientID, osBuild: osBuild, modelName: "Mac")
            let api = MRPAPI(protocolLayer: mrpProtocol)
            api.onDisconnect = { [weak self] in self?.handleDisconnect() }
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

        // Intentional disconnect: detach onDisconnect first so "unexpected disconnect" is not reported.
        companion?.onDisconnect = nil
        mrp?.onDisconnect = nil
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

    /// Connection dropped unexpectedly (remote reboot/network change): clean up state and notify the user.
    private func handleDisconnect() {
        stopStatusTimer()
        connectionLock.lock()
        let companion = companionAPI
        let mrp = mrpAPI
        companionAPI = nil
        mrpAPI = nil
        connectionLock.unlock()

        // The connection is already down; nil them out to prevent repeated triggers.
        companion?.onDisconnect = nil
        mrp?.onDisconnect = nil

        DispatchQueue.main.async {
            self.connectionState = .disconnected
            self.currentDevice = nil
            self.nowPlaying = nil
            self.apps = []
            self.lastError = "Connection lost. Reconnect from Settings"
            self.defaults.removeObject(forKey: "lastDeviceIdentifier")
        }
    }

    // MARK: - Control Commands

    func sendKey(_ key: RemoteKey) async {
        guard let companion = currentCompanion() else {
            setError(BridgeError.message("Not connected to an Apple TV. Connect from Settings first"))
            return
        }
        do {
            try await performKey(key, on: companion)
            // A successful command means the connection is fine; clear the previous transient error.
            DispatchQueue.main.async { self.lastError = nil }
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
            setError(BridgeError.message("Not connected to an Apple TV. Connect from Settings first"))
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
            // A successful command means the connection is fine; clear the previous transient error.
            DispatchQueue.main.async { self.lastError = nil }
        } catch {
            setError(error)
        }
    }

    func volume(_ action: String) async {
        guard let companion = currentCompanion() else {
            setError(BridgeError.message("Not connected to an Apple TV. Connect from Settings first"))
            return
        }
        do {
            if action == "up" {
                try await companion.press(.volumeUp)
            } else {
                try await companion.press(.volumeDown)
            }
            DispatchQueue.main.async { self.lastError = nil }
        } catch {
            setError(error)
        }
    }

    func loadApps() async {
        guard let companion = currentCompanion() else {
            setError(BridgeError.message("Not connected to an Apple TV. Connect from Settings first"))
            return
        }
        // Throttle after failure: some firmware ignores FetchLaunchableApplicationsEvent,
        // so the request only ends in a timeout; retrying repeatedly is pointless.
        guard Date().timeIntervalSince(lastAppsLoadAttempt) >= 60 else { return }
        lastAppsLoadAttempt = Date()
        do {
            let list = try await companion.appList()
            let found = list.map { RemoteApp(identifier: $0.key, name: $0.value) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async { self.apps = found }
        } catch {
            // An unavailable app list does not affect core remote features (keys/media/power);
            // handle it silently rather than showing "device response timed out" and making
            // the user think the connection is broken.
            logger.error("Failed to fetch app list: \(String(describing: error), privacy: .public)")
        }
    }

    func launchApp(_ identifier: String) async {
        guard let companion = currentCompanion() else {
            setError(BridgeError.message("Not connected to an Apple TV. Connect from Settings first"))
            return
        }
        do {
            try await companion.launchApp(identifier)
        } catch {
            setError(error)
        }
    }

    // MARK: - Status

    func pollStatus() async {
        let mrp = currentMRP()
        let companion = currentCompanion()
        guard mrp != nil || companion != nil else { return }

        let np = mrp?.nowPlaying()
        let artwork = mrp?.artwork()

        var powerState: String?
        if let companion, Date().timeIntervalSince(lastPowerPoll) >= powerPollInterval {
            lastPowerPoll = Date()
            do {
                let state = try await companion.fetchAttentionState()
                powerState = powerStateString(state)
                powerPollInterval = 5
            } catch {
                // When firmware ignores the command, the request only ends in a timeout; back off exponentially to reduce polling frequency.
                powerPollInterval = min(powerPollInterval * 2, 60)
            }
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

    // MARK: - Lifecycle

    func stop() {
        discovery.stop()
        stopStatusTimer()
        connectionLock.lock()
        let companion = companionAPI
        let mrp = mrpAPI
        companionAPI = nil
        mrpAPI = nil
        connectionLock.unlock()

        // Cleanup on app exit: detach disconnect callbacks so UI updates are not triggered during shutdown.
        companion?.onDisconnect = nil
        mrp?.onDisconnect = nil
        if companion != nil || mrp != nil {
            Task {
                try? await companion?.disconnect()
                mrp?.disconnect()
            }
        }
    }

    private func startStatusTimer() {
        stopStatusTimer()
        // Use DispatchSourceTimer instead of Timer.scheduledTimer: the latter is registered
        // on the current thread's RunLoop, and a background thread's RunLoop does not run on
        // its own, so the timer would never fire.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.pollStatus() }
        }
        timer.resume()
        statusTimer = timer
    }

    private func stopStatusTimer() {
        statusTimer?.cancel()
        statusTimer = nil
    }

    // MARK: - Helpers

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

    /// The current macOS system build number (e.g. "23A344"), used in MRP DeviceInfo.
    private var osBuild: String {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("kern.osversion", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}
