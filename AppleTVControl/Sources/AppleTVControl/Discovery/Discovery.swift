// 设备发现:通过 Bonjour (mDNS) 扫描局域网里的 Apple TV。
//
// 对应 pyatv 的 `pyatv.scan`。Apple TV 通过两个服务宣告自己:
//   - `_mediaremotetv._tcp`   (MRP,设备控制)
//   - `_companion-link._tcp`  (Companion,配对 + 应用/键盘等)
// 两者用同一个 identifier 关联(MRP 的 `UniqueIdentifier` / Companion 的 `rpmrtid`),
// 聚合后即为一台完整的设备。

import Foundation

/// 服务种类。
public enum ServiceKind: String {
    case mrp
    case companion

    /// 由 mDNS service type(如 "_mediaremotetv._tcp.")判断服务种类。
    public static func from(serviceType: String) -> ServiceKind? {
        if serviceType.hasPrefix("_mediaremotetv._tcp") { return .mrp }
        if serviceType.hasPrefix("_companion-link._tcp") { return .companion }
        return nil
    }
}

/// 发现的一台 Apple TV(聚合 MRP + Companion 两个服务)。
public struct ATVDevice {
    public let identifier: String
    public let name: String
    public let host: String
    public let model: String
    public let companionPort: Int?
    public let mrpPort: Int?
    /// 合并后的 TXT 属性(MRP 与 Companion 键合并)。
    public let txt: [String: String]

    public init(
        identifier: String, name: String, host: String, model: String,
        companionPort: Int?, mrpPort: Int?, txt: [String: String]
    ) {
        self.identifier = identifier
        self.name = name
        self.host = host
        self.model = model
        self.companionPort = companionPort
        self.mrpPort = mrpPort
        self.txt = txt
    }

    public var isCompanionSupported: Bool { companionPort != nil }
    public var isMRPSupported: Bool { mrpPort != nil }
}

/// 解析单个 mDNS 服务得到的中间信息。
public struct ResolvedService {
    public let kind: ServiceKind
    public let name: String
    public let host: String
    public let port: Int
    public let properties: [String: String]

    public init(kind: ServiceKind, name: String, host: String, port: Int, properties: [String: String]) {
        self.kind = kind
        self.name = name
        self.host = host
        self.port = port
        self.properties = properties
    }

    /// 该服务的唯一标识:MRP 用 `UniqueIdentifier`,Companion 用 `rpmrtid`。
    public var identifier: String? {
        switch kind {
        case .mrp: return properties["UniqueIdentifier"]
        case .companion: return properties["rpmrtid"]
        }
    }
}

/// 解析 TXT record(RFC 6763)字节为键值字典。
/// 每个条目为 `<1 字节长度><key=value>`,空 value 表示 key 存在但无值。
public func parseTXTRecord(_ data: Data) -> [String: String] {
    var result: [String: String] = [:]
    var offset = 0
    let bytes = [UInt8](data)
    while offset < bytes.count {
        let length = Int(bytes[offset])
        offset += 1
        guard offset + length <= bytes.count else { break }
        let entry = Data(bytes[offset..<(offset + length)])
        offset += length
        guard let text = String(data: entry, encoding: .utf8) else { continue }
        if let eq = text.firstIndex(of: "=") {
            let key = String(text[..<eq])
            let value = String(text[text.index(after: eq)...])
            result[key] = value
        } else {
            result[text] = ""
        }
    }
    return result
}

/// 设备聚合器:把 MRP 与 Companion 两个服务按 identifier 合并成一台设备。
/// 独立成纯结构,便于单元测试。
public struct DeviceAggregator {
    public var mrp: ResolvedService?
    public var companion: ResolvedService?

    public init() {}

    public mutating func add(_ service: ResolvedService) {
        switch service.kind {
        case .mrp: mrp = service
        case .companion: companion = service
        }
    }

    public func build() -> ATVDevice? {
        guard let identifier = mrp?.identifier ?? companion?.identifier else { return nil }
        let name = mrp?.properties["Name"] ?? companion?.name ?? "未知设备"
        let host = mrp?.host ?? companion?.host ?? ""
        let model = companion.flatMap { s in
            s.properties["rpmd"].map { DeviceModel.lookup($0).rawValue }
        } ?? "未知设备"
        var txt = mrp?.properties ?? [:]
        companion?.properties.forEach { txt[$0.key] = $0.value }
        return ATVDevice(
            identifier: identifier,
            name: name,
            host: host,
            model: model,
            companionPort: companion?.port,
            mrpPort: mrp?.port,
            txt: txt
        )
    }
}

/// Bonjour 发现器。回调在主线程 RunLoop 上派发。
public final class DeviceDiscovery: NSObject {
    public var onDevicesUpdated: (([ATVDevice]) -> Void)?

    private let serviceTypes: [(String, ServiceKind)] = [
        ("_mediaremotetv._tcp.", .mrp),
        ("_companion-link._tcp.", .companion),
    ]

    private var browsers: [NetServiceBrowser] = []
    private var pendingServices: [NetService] = []
    private var aggregators: [String: DeviceAggregator] = [:]

    public override init() {
        super.init()
    }

    /// 开始扫描,发现/更新设备时回调 `onDevicesUpdated`。
    public func start() {
        stop()
        for (type, _) in serviceTypes {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.searchForServices(ofType: type, inDomain: "local.")
            browsers.append(browser)
        }
    }

    public func stop() {
        browsers.forEach { $0.stop() }
        browsers.removeAll()
        pendingServices.removeAll()
    }

    private func publishDevices() {
        let devices = aggregators.values.compactMap { $0.build() }
            .sorted { $0.name < $1.name }
        onDevicesUpdated?(devices)
    }
}

// MARK: - NetServiceBrowserDelegate

extension DeviceDiscovery: NetServiceBrowserDelegate {
    public func netServiceBrowser(
        _ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool
    ) {
        service.delegate = self
        service.resolve(withTimeout: 10)
        pendingServices.append(service)
    }

    public func netServiceBrowser(
        _ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool
    ) {
        // 简化处理:移除时重新扫描;完整实现可按 identifier 删除。
        // pyatv 同样在设备下线时通过 mDNS goodbye 包感知,这里暂不细究。
    }

    public func netServiceBrowser(
        _ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]
    ) {
        // 扫描失败(如无网络),回调空结果。
        onDevicesUpdated?([])
    }
}

// MARK: - NetServiceDelegate

extension DeviceDiscovery: NetServiceDelegate {
    public func netServiceDidResolve(_ sender: NetService) {
        defer { pendingServices.removeAll { $0 === sender } }
        guard let kind = ServiceKind.from(serviceType: sender.type),
              let data = sender.txtRecordData() else { return }

        let service = ResolvedService(
            kind: kind,
            name: sender.name,
            host: sender.hostName ?? "",
            port: sender.port,
            properties: parseTXTRecord(data)
        )
        guard let identifier = service.identifier else { return }

        var aggregator = aggregators[identifier] ?? DeviceAggregator()
        aggregator.add(service)
        aggregators[identifier] = aggregator
        publishDevices()
    }

    public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        pendingServices.removeAll { $0 === sender }
    }
}
