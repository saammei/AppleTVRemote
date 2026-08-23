import Foundation
import Combine

enum BridgeError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}

final class ATVBridge: ObservableObject {
    static weak var shared: ATVBridge?

    enum BridgeState: Equatable {
        case stopped
        case starting
        case ready
        case failed(String)

        var label: String {
            switch self {
            case .stopped: "已停止"
            case .starting: "启动中…"
            case .ready: "就绪"
            case .failed(let message): "启动失败：\(message)"
            }
        }
    }

    @Published private(set) var bridgeState: BridgeState = .stopped
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var devices: [ATVDevice] = []
    @Published private(set) var currentDevice: ATVDevice?
    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var apps: [RemoteApp] = []
    @Published private(set) var pairingAwaitingPin = false
    @Published private(set) var isScanning = false
    @Published private(set) var isPairing = false
    @Published private(set) var bridgeLog: String = ""
    @Published var lastError: String?

    private var process: Process?
    private var inputPipe: Pipe?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private let ioQueue = DispatchQueue(label: "atv.bridge.io")
    private let lock = NSLock()
    private var pending: [Int: CheckedContinuation<Any?, Error>] = [:]
    private var nextRequestID = 1
    private var shouldKeepRunning = false
    private var restartAttempts = 0
    private var statusTimer: Timer?

    private let defaults = UserDefaults.standard

    init() {
        ATVBridge.shared = self
    }

    deinit {
        stop()
    }

    // MARK: - Paths

    private var appSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppleTVRemote", isDirectory: true)
    }

    var storageURL: URL {
        appSupportURL.appendingPathComponent("pyatv.json")
    }

    private var defaultPythonPath: String {
        appSupportURL.appendingPathComponent("venv/bin/python3").path
    }

    var pythonPath: String {
        ProcessInfo.processInfo.environment["ATV_BRIDGE_PYTHON"] ?? defaultPythonPath
    }

    private func scriptURL() -> URL? {
        if let url = Bundle.main.url(forResource: "bridge", withExtension: "py", subdirectory: "Backend") {
            return url
        }
        return Bundle.main.url(forResource: "bridge", withExtension: "py")
    }

    // MARK: - Lifecycle

    func start() {
        guard process == nil else { return }
        shouldKeepRunning = true
        DispatchQueue.main.async { self.bridgeState = .starting }

        guard FileManager.default.isExecutableFile(atPath: pythonPath) else {
            DispatchQueue.main.async { self.bridgeState = .failed("未找到 Python 环境：\(self.pythonPath)\n请运行 scripts/setup.sh") }
            return
        }
        guard let script = scriptURL() else {
            DispatchQueue.main.async { self.bridgeState = .failed("找不到 bridge.py 资源") }
            return
        }

        do {
            try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
            try launch(python: pythonPath, script: script)
        } catch {
            DispatchQueue.main.async { self.bridgeState = .failed("启动失败：\(error.localizedDescription)") }
        }
    }

    func restart() {
        shouldKeepRunning = false
        let old = process
        process = nil
        old?.terminate()
        old?.waitUntilExit()
        failAllPending("后端已重启")
        shouldKeepRunning = true
        DispatchQueue.main.async { self.bridgeState = .stopped }
        start()
    }

    func stop() {
        shouldKeepRunning = false
        let old = process
        process = nil
        old?.terminate()
        failAllPending("后端已停止")
        stopStatusTimer()
    }

    private func launch(python: String, script: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = ["-u", script.path, "--storage", storageURL.path, "--log-level", "INFO"]

        let input = Pipe()
        let output = Pipe()
        let errorOutput = Pipe()
        proc.standardInput = input
        proc.standardOutput = output
        proc.standardError = errorOutput

        proc.terminationHandler = { [weak self, weak proc] _ in
            DispatchQueue.main.async {
                guard let self, let proc, self.process === proc else { return }
                self.process = nil
                self.inputPipe = nil
                self.connectionState = .disconnected
                self.nowPlaying = nil
                self.failAllPending("后端进程已退出")
                if self.shouldKeepRunning {
                    self.bridgeState = .starting
                    let delay = min(2.0 * pow(2.0, Double(min(self.restartAttempts, 4))), 10.0)
                    self.restartAttempts += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.start()
                    }
                } else {
                    self.bridgeState = .stopped
                }
            }
        }

        try proc.run()
        process = proc
        inputPipe = input

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeStdout(handle)
        }
        errorOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeStderr(handle)
        }
    }

    // MARK: - Process I/O

    private func consumeStdout(_ handle: FileHandle) {
        let data = handle.availableData
        guard !data.isEmpty else { return }
        stdoutBuffer.append(data)

        var start = stdoutBuffer.startIndex
        while let range = stdoutBuffer[start...].range(of: Data([0x0A])) {
            let lineData = stdoutBuffer.subdata(in: start..<range.lowerBound)
            start = range.upperBound
            guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
            handleLine(line)
        }
        stdoutBuffer.removeSubrange(stdoutBuffer.startIndex..<start)
    }

    private func consumeStderr(_ handle: FileHandle) {
        let data = handle.availableData
        guard !data.isEmpty else { return }
        stderrBuffer.append(data)
        let maxLength = 12_000
        if stderrBuffer.count > maxLength {
            stderrBuffer.removeSubrange(stderrBuffer.startIndex..<(stderrBuffer.index(stderrBuffer.endIndex, offsetBy: -(maxLength / 2))))
        }
        let text = String(data: stderrBuffer, encoding: .utf8) ?? ""
        let lines = text.components(separatedBy: "\n").suffix(200)
        DispatchQueue.main.async {
            self.bridgeLog = lines.joined(separator: "\n")
        }
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if let event = obj["event"] as? String {
            DispatchQueue.main.async { self.handleEvent(event, payload: obj) }
            return
        }

        guard let id = obj["id"] as? Int else { return }
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        guard let continuation else { return }

        if let ok = obj["ok"] as? Bool, ok {
            continuation.resume(returning: obj["result"])
        } else {
            let message = obj["error"] as? String ?? "未知错误"
            continuation.resume(throwing: BridgeError.message(message))
        }
    }

    private func handleEvent(_ event: String, payload: [String: Any]) {
        switch event {
        case "connection":
            if payload["state"] as? String == "connected" {
                connectionState = .connected
                bridgeState = .ready
                restartAttempts = 0
                startStatusTimer()
            } else {
                connectionState = .disconnected
                stopStatusTimer()
            }
        case "pairing":
            switch payload["state"] as? String {
            case "awaiting_pin":
                pairingAwaitingPin = true
                isPairing = true
            case "done":
                pairingAwaitingPin = false
                isPairing = false
            case "failed":
                pairingAwaitingPin = false
                isPairing = false
            default:
                break
            }
        case "log":
            if let message = payload["message"] as? String {
                appendLog(message)
                if message.contains("bridge ready") {
                    bridgeState = .ready
                    restartAttempts = 0
                }
            }
        default:
            break
        }
    }

    private func appendLog(_ message: String) {
        var lines = bridgeLog.components(separatedBy: "\n")
        lines.insert(message, at: 0)
        if lines.count > 300 { lines.removeLast(lines.count - 300) }
        bridgeLog = lines.joined(separator: "\n")
    }

    private func failAllPending(_ message: String) {
        lock.lock()
        let continuations = Array(pending.values)
        pending.removeAll()
        lock.unlock()
        for continuation in continuations {
            continuation.resume(throwing: BridgeError.message(message))
        }
    }

    // MARK: - Request plumbing

    private func ensureRunning() {
        guard process == nil else { return }
        if case .failed = bridgeState { return }
        start()
    }

    @discardableResult
    func request(_ op: String, params: [String: Any] = [:], timeout: TimeInterval = 40) async throws -> Any? {
        ensureRunning()
        guard process != nil else {
            throw BridgeError.message("后端未运行")
        }

        let id = nextRequestID
        nextRequestID += 1

        var payload: [String: Any] = ["id": id, "op": op]
        if !params.isEmpty { payload["params"] = params }
        let data = try JSONSerialization.data(withJSONObject: payload)

        return try await withThrowingTaskGroup(of: Any?.self) { group in
            group.addTask {
                try await self.waitForReply(id: id, data: data)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.lock.lock()
                let continuation = self.pending.removeValue(forKey: id)
                self.lock.unlock()
                if let continuation {
                    continuation.resume(throwing: BridgeError.message("请求超时（\(op)）"))
                }
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw BridgeError.message("请求失败（\(op)）")
            }
            return first
        }
    }

    private func waitForReply(id: Int, data: Data) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            lock.lock()
            pending[id] = continuation
            lock.unlock()
            guard let input = inputPipe else {
                continuation.resume(throwing: BridgeError.message("后端未运行"))
                return
            }
            do {
                var data = data
                data.append(0x0A)
                try input.fileHandleForWriting.write(contentsOf: data)
            } catch {
                continuation.resume(throwing: BridgeError.message("写入后端失败：\(error.localizedDescription)"))
            }
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from value: Any) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: value)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }

    // MARK: - High-level operations

    func scanDevices() async {
        DispatchQueue.main.async { self.isScanning = true }
        defer { DispatchQueue.main.async { self.isScanning = false } }
        do {
            guard let result = try await request("scan", params: ["timeout": 6], timeout: 25) else { return }
            let found = try Self.decode([ATVDevice].self, from: result)
            DispatchQueue.main.async { self.devices = found }
        } catch {
            setError(error)
        }
    }

    func pairBegin(device: ATVDevice) async {
        DispatchQueue.main.async { self.isPairing = true }
        do {
            _ = try await request("pair_begin", params: ["identifier": device.identifier])
            DispatchQueue.main.async { self.pairingAwaitingPin = true }
        } catch {
            DispatchQueue.main.async { self.isPairing = false }
            setError(error)
        }
    }

    func pairFinish(pin: String) async {
        do {
            _ = try await request("pair_finish", params: ["pin": pin])
            DispatchQueue.main.async {
                self.pairingAwaitingPin = false
                self.isPairing = false
            }
        } catch {
            DispatchQueue.main.async {
                self.pairingAwaitingPin = false
                self.isPairing = false
            }
            setError(error)
        }
    }

    func connect(device: ATVDevice) async {
        DispatchQueue.main.async { self.connectionState = .connecting }
        do {
            try await performConnect(identifier: device.identifier)
        } catch {
            DispatchQueue.main.async { self.connectionState = .failed(error.localizedDescription) }
        }
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
        guard let result = try await request("connect", params: ["identifier": identifier], timeout: 30) else { return }
        let info = try Self.decode(ConnectedDeviceInfo.self, from: result)
        let device = ATVDevice(
            identifier: info.identifier,
            name: info.name,
            address: "",
            model: info.model,
            services: []
        )
        DispatchQueue.main.async {
            self.currentDevice = device
            self.connectionState = .connected
            self.defaults.set(identifier, forKey: "lastDeviceIdentifier")
            self.lastError = nil
        }
        await pollStatus()
    }

    func disconnect() async {
        _ = try? await request("disconnect", timeout: 10)
        DispatchQueue.main.async {
            self.connectionState = .disconnected
            self.currentDevice = nil
            self.nowPlaying = nil
            self.defaults.removeObject(forKey: "lastDeviceIdentifier")
        }
    }

    func sendKey(_ key: RemoteKey) async {
        do {
            _ = try await request("key", params: ["key": key.rawValue], timeout: 10)
        } catch {
            setError(error)
        }
    }

    func power(_ action: String) async {
        do {
            _ = try await request("power", params: ["action": action], timeout: 15)
            await pollStatus()
        } catch {
            setError(error)
        }
    }

    func volume(_ action: String) async {
        do {
            _ = try await request("volume", params: ["action": action], timeout: 10)
        } catch {
            setError(error)
        }
    }

    func loadApps() async {
        do {
            guard let result = try await request("apps", timeout: 15) else { return }
            let found = try Self.decode([RemoteApp].self, from: result)
            DispatchQueue.main.async { self.apps = found }
        } catch {
            setError(error)
        }
    }

    func launchApp(_ identifier: String) async {
        do {
            _ = try await request("launch", params: ["app": identifier], timeout: 10)
        } catch {
            setError(error)
        }
    }

    func pollStatus() async {
        guard process != nil else { return }
        do {
            guard let result = try await request("status", timeout: 8) else { return }
            let playing = try Self.decode(NowPlaying.self, from: result)
            DispatchQueue.main.async { self.nowPlaying = playing }
        } catch {
            DispatchQueue.main.async { self.connectionState = .failed(error.localizedDescription) }
        }
    }

    func autoConnectIfNeeded() {
        guard let identifier = defaults.string(forKey: "lastDeviceIdentifier") else { return }
        Task { await connect(identifier: identifier) }
    }

    private func setError(_ error: Error) {
        DispatchQueue.main.async { self.lastError = error.localizedDescription }
    }

    // MARK: - Status polling

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
}

private struct ConnectedDeviceInfo: Decodable {
    let identifier: String
    let name: String
    let model: String
}
