// Device discovery: scans the LAN for Apple TVs via Bonjour (mDNS).
//
// Corresponds to pyatv's `pyatv.scan`. Apple TVs advertise themselves via two services:
//   - `_mediaremotetv._tcp`   (MRP, device control)
//   - `_companion-link._tcp`  (Companion, pairing + apps/keyboard, etc.)
// Both are linked by the same identifier (MRP's `UniqueIdentifier` / Companion's `rpmrtid`);
// aggregating them yields one complete device.

import Foundation
import os
import CDNSSD

/// Service kind.
public enum ServiceKind: String {
    case mrp
    case companion

    /// Determines the service kind from the mDNS service type (e.g. "_mediaremotetv._tcp.").
    public static func from(serviceType: String) -> ServiceKind? {
        if serviceType.hasPrefix("_mediaremotetv._tcp") { return .mrp }
        if serviceType.hasPrefix("_companion-link._tcp") { return .companion }
        return nil
    }
}

/// A discovered Apple TV (aggregating both the MRP and Companion services).
public struct DiscoveredDevice {
    public let identifier: String
    public let name: String
    public let host: String
    public let model: String
    public let companionPort: Int?
    public let mrpPort: Int?
    /// Merged TXT properties (MRP and Companion keys combined).
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

/// Intermediate information parsed from a single mDNS service.
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

    /// This service's unique identifier: MRP uses `UniqueIdentifier`, Companion uses `rpmrtid`.
    /// Note: key names are normalized to lowercase per RFC 6763 (what is actually broadcast is
    /// mixed-case like `rpMRtID`).
    public var identifier: String? {
        switch kind {
        case .mrp: return properties["uniqueidentifier"]
        case .companion: return properties["rpmrtid"]
        }
    }
}

/// Parses TXT record (RFC 6763) bytes into a key/value dictionary.
/// Each entry is `<1 byte length><key=value>`; an empty value means the key exists without a value.
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
            // RFC 6763: key names are case-insensitive, so normalize to lowercase. Apple TVs
            // actually broadcast mixed-case keys like `rpMRtID` and `rpMd`; python-zeroconf
            // lowercases them too, so we must match, otherwise the identifier is not found
            // and the device is silently dropped.
            result[key.lowercased()] = value
        } else {
            result[text.lowercased()] = ""
        }
    }
    return result
}

/// Device aggregator: merges the MRP and Companion services into one device by identifier.
/// Kept as a standalone pure struct for easy unit testing.
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

    public func build() -> DiscoveredDevice? {
        guard let identifier = mrp?.identifier ?? companion?.identifier else { return nil }
        let name = mrp?.properties["name"] ?? companion?.name ?? "Unknown Device"
        let host = mrp?.host ?? companion?.host ?? ""
        let model = companion.flatMap { s in
            s.properties["rpmd"].map { DeviceModel.lookup($0).rawValue }
        } ?? "Unknown Device"
        var txt = mrp?.properties ?? [:]
        companion?.properties.forEach { txt[$0.key] = $0.value }
        return DiscoveredDevice(
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

/// Errors that occur during scanning.
public enum DiscoveryError: Error, CustomStringConvertible, Equatable {
    /// The system "Local Network" permission was denied (macOS 15+ privacy setting).
    case localNetworkDenied
    /// Other scan failures, with an error code.
    case searchFailed(code: Int)

    public var description: String {
        switch self {
        case .localNetworkDenied:
            return "Local network permission denied (error code -65553)"
        case .searchFailed(let code):
            return "Scan failed (error code \(code))"
        }
    }
}

/// Bonjour discoverer. Callbacks are dispatched on the main thread's RunLoop.
public final class DeviceDiscovery: NSObject {
    public var onDevicesUpdated: (([DiscoveredDevice]) -> Void)?
    /// Called when a scan error occurs (e.g. local network permission denied).
    public var onSearchError: ((DiscoveryError) -> Void)?

    private let logger = Logger(subsystem: "com.meishaoming.AppleTVRemote", category: "discovery")

    private let serviceTypes: [(String, ServiceKind)] = [
        ("_mediaremotetv._tcp.", .mrp),
        ("_companion-link._tcp.", .companion),
    ]

    private var browsers: [NetServiceBrowser] = []
    private var pendingServices: [NetService] = []
    private var aggregators: [String: DeviceAggregator] = [:]
    /// In-flight C API resolves (held by object identity so the context stays alive during callbacks).
    private var resolveBoxes: [ObjectIdentifier: ResolveContext] = [:]

    public override init() {
        super.init()
    }

    /// Starts scanning; calls back `onDevicesUpdated` when devices are found/updated.
    ///
    /// Note: NetServiceBrowser callbacks depend on the RunLoop of the thread that created the
    /// browser — if called from a background thread without a RunLoop, the browser stays silent
    /// (no didFind, no didNotSearch either). We therefore dispatch browser creation and stopping
    /// to the main thread so any thread can call this.
    public func start() {
        if Thread.isMainThread {
            startOnMain()
        } else {
            DispatchQueue.main.async { [weak self] in self?.startOnMain() }
        }
    }

    public func stop() {
        if Thread.isMainThread {
            stopOnMain()
        } else {
            DispatchQueue.main.async { [weak self] in self?.stopOnMain() }
        }
    }

    private func startOnMain() {
        stopOnMain()
        aggregators.removeAll()  // every scan starts fresh, avoiding stale devices that went offline
        for (type, _) in serviceTypes {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.searchForServices(ofType: type, inDomain: "local.")
            browsers.append(browser)
        }
        logger.debug("Starting scan \(self.serviceTypes.map(\.0), privacy: .public)")
    }

    private func stopOnMain() {
        browsers.forEach { $0.stop() }
        browsers.removeAll()
        pendingServices.removeAll()
        // End all in-flight resolves: mark finalized and release the C refs first (no callbacks
        // after that), then clear the collection.
        for box in resolveBoxes.values {
            box.finalized = true
            if let ref = box.sdRef {
                DNSServiceRefDeallocate(ref)
                box.sdRef = nil
            }
        }
        resolveBoxes.removeAll()
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
        pendingServices.append(service)
        resolveViaDNSSD(service)
        logger.debug("didFind \(service.name, privacy: .public) type=\(service.type, privacy: .public)")
    }

    public func netServiceBrowser(
        _ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool
    ) {
        // Simplified handling: re-scan on removal; a full implementation could remove by identifier.
        // pyatv also notices device shutdown via mDNS goodbye packets; not investigated here.
    }

    public func netServiceBrowser(
        _ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]
    ) {
        // Scan failed. On macOS 15+, when the "Local Network" permission is denied, the browser
        // fails with kDNSServiceErr_PolicyDenied (-65553), and the system no longer shows the
        // authorization prompt, so the user must be guided to enable it manually in
        // System Settings → Privacy & Security → Local Network.
        let code = errorDict[NetService.errorCode]?.intValue ?? 0
        logger.error("didNotSearch \(code, privacy: .public) \(errorDict, privacy: .public)")
        if code == -65553 {
            onSearchError?(.localNetworkDenied)
        } else {
            onSearchError?(.searchFailed(code: code))
        }
        onDevicesUpdated?([])
    }
}

// MARK: - C DNS-SD resolve
//
// On macOS 26, NetService.resolve callbacks are not dispatched (measured: mDNSResponder returns
// all SRV/TXT/A/AAAA results, but didResolve/didNotResolve never fire — reproduced in both the CLI
// and the app). The resolve step therefore uses the C API DNSServiceResolve, whose callbacks go
// through a dispatch queue and do not depend on the RunLoop.

/// Context for DNSServiceResolve, passed back through the C context pointer.
///
/// The resolve callback fires multiple times (once per SRV/TXT/RESULT event); data from multiple
/// callbacks is merged until host/port/TXT are all complete.
private final class ResolveContext {
    let kind: ServiceKind
    let name: String
    weak var discovery: DeviceDiscovery?

    private(set) var host: String = ""
    private(set) var port: UInt16 = 0
    private(set) var txt: Data?
    fileprivate(set) var finalized = false
    fileprivate(set) var sdRef: DNSServiceRef?

    init(kind: ServiceKind, name: String, discovery: DeviceDiscovery) {
        self.kind = kind
        self.name = name
        self.discovery = discovery
    }

    /// Merges one callback's data; returns true when everything is complete.
    func merge(host: String, port: UInt16, txt: Data?) -> Bool {
        if !host.isEmpty {
            self.host = host
        }
        if port != 0 {
            self.port = port
        }
        if let txt {
            self.txt = txt
        }
        return !self.host.isEmpty && self.port != 0 && self.txt != nil
    }
}

/// C callback for DNSServiceResolve (fired on a dispatch queue, possibly multiple times).
/// Ownership of the context belongs to DeviceDiscovery.resolveBoxes; no retain/release in the callback.
private func dnsSDResolveCallback(
    _ sdRef: DNSServiceRef?,
    _ flags: DNSServiceFlags,
    _ interfaceIndex: UInt32,
    _ errorCode: DNSServiceErrorType,
    _ fullname: UnsafePointer<CChar>?,
    _ hosttarget: UnsafePointer<CChar>?,
    _ port: UInt16,
    _ txtLen: UInt16,
    _ txtRecord: UnsafePointer<UInt8>?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let box = Unmanaged<ResolveContext>.fromOpaque(context).takeUnretainedValue()
    // The C buffers are only valid during the callback, so copy them into Swift values before
    // passing across threads.
    let host = hosttarget.map { String(cString: $0) } ?? ""
    let txt: Data?
    if txtLen > 0, let txtRecord {
        txt = Data(bytes: txtRecord, count: Int(txtLen))
    } else {
        txt = nil
    }
    // Handle everything on the main thread (same as browser callbacks), so the aggregator needs no locking.
    DispatchQueue.main.async {
        box.discovery?.handleResolveCallback(
            box: box, errorCode: errorCode, host: host, port: port, txt: txt
        )
    }
}

extension DeviceDiscovery {
    /// Resolves the service using the C API (replacing NetService.resolve).
    private func resolveViaDNSSD(_ service: NetService) {
        guard let kind = ServiceKind.from(serviceType: service.type) else { return }
        let box = ResolveContext(kind: kind, name: service.name, discovery: self)
        resolveBoxes[ObjectIdentifier(box)] = box
        let context = Unmanaged.passUnretained(box).toOpaque()
        var ref: DNSServiceRef?
        let err = service.name.withCString { name in
            service.type.withCString { type in
                service.domain.withCString { domain in
                    DNSServiceResolve(&ref, 0, 0, name, type, domain, dnsSDResolveCallback, context)
                }
            }
        }
        guard err == kDNSServiceErr_NoError else {
            logger.error("DNSServiceResolve failed to start \(err, privacy: .public)")
            resolveBoxes.removeValue(forKey: ObjectIdentifier(box))
            if err == kDNSServiceErr_PolicyDenied {
                onSearchError?(.localNetworkDenied)
            }
            return
        }
        box.sdRef = ref
        if let ref {
            DNSServiceSetDispatchQueue(ref, .main)
        }
    }

    /// Handles the C API resolve callback (main queue). Merges data from multiple callbacks
    /// and only publishes when everything is complete.
    fileprivate func handleResolveCallback(
        box: ResolveContext, errorCode: DNSServiceErrorType,
        host: String, port: UInt16, txt: Data?
    ) {
        guard !box.finalized else { return }
        guard errorCode == kDNSServiceErr_NoError else {
            finishResolve(box)
            logger.error("resolve failed \(box.name, privacy: .public) code=\(errorCode, privacy: .public)")
            if errorCode == kDNSServiceErr_PolicyDenied {
                onSearchError?(.localNetworkDenied)
            }
            return
        }
        guard box.merge(host: host, port: port, txt: txt) else { return }
        let properties = box.txt.map(parseTXTRecord) ?? [:]
        finishResolve(box)

        let host = box.host
        let resolved = ResolvedService(
            kind: box.kind,
            name: box.name,
            host: host,
            port: Int(UInt16(bigEndian: box.port)),
            properties: properties
        )
        logger.debug("resolved \(box.name, privacy: .public) kind=\(box.kind.rawValue, privacy: .public) host=\(host, privacy: .public) port=\(resolved.port, privacy: .public) txt=\(properties, privacy: .public)")

        guard let identifier = resolved.identifier else {
            logger.error("service \(box.name, privacy: .public) missing identifier, dropping")
            return
        }

        var aggregator = aggregators[identifier] ?? DeviceAggregator()
        aggregator.add(resolved)
        aggregators[identifier] = aggregator
        publishDevices()
    }

    /// Ends a resolve: releases the C ref (no more callbacks after that) and removes it from the in-flight set.
    private func finishResolve(_ box: ResolveContext) {
        box.finalized = true
        if let ref = box.sdRef {
            DNSServiceRefDeallocate(ref)
            box.sdRef = nil
        }
        resolveBoxes.removeValue(forKey: ObjectIdentifier(box))
    }
}
