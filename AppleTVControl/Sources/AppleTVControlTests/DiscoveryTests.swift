import Foundation
import AppleTVControl

/// Builds TXT record bytes (for testing).
func makeTXTRecord(_ entries: [String: String]) -> Data {
    var data = Data()
    for (key, value) in entries {
        let text = value.isEmpty ? key : "\(key)=\(value)"
        let bytes = [UInt8](text.utf8)
        data.append(UInt8(bytes.count))
        data.append(contentsOf: bytes)
    }
    return data
}

func runDiscoveryTests() {
    runSuite("TXT record parsing") {
        let data = makeTXTRecord([
            "Name": "Living Room",
            "UniqueIdentifier": "abc-123",
            "allowpairing": "yes",
        ])
        let props = parseTXTRecord(data)
        // RFC 6763: keys are normalized to lowercase
        expectEqual(props["name"], "Living Room", "name")
        expectEqual(props["uniqueidentifier"], "abc-123", "uniqueidentifier")
        expectEqual(props["allowpairing"], "yes", "allowpairing")
        expect(props["Name"] == nil, "uppercase key absent (normalized)")
    }

    runSuite("TXT key casing (Apple TV broadcasts mixed-case keys)") {
        let data = makeTXTRecord([
            "rpMRtID": "578B0CD2-84C4-4612-9A8A-12A2FD78EF8C",
            "rpMd": "AppleTV14,1",
            "rpFl": "0x36782",
        ])
        let props = parseTXTRecord(data)
        expectEqual(props["rpmrtid"], "578B0CD2-84C4-4612-9A8A-12A2FD78EF8C", "rpmrtid lowercase lookup")
        expectEqual(props["rpmd"], "AppleTV14,1", "rpmd lowercase lookup")
        expectEqual(props["rpfl"], "0x36782", "rpfl lowercase lookup")
    }

    runSuite("service type classification") {
        expectEqual(ServiceKind.from(serviceType: "_mediaremotetv._tcp."), .mrp, "MRP type")
        expectEqual(ServiceKind.from(serviceType: "_companion-link._tcp."), .companion, "Companion type")
        expectEqual(ServiceKind.from(serviceType: "_airplay._tcp."), nil, "unknown type")
    }

    runSuite("device aggregation") {
        let mrp = ResolvedService(
            kind: .mrp, name: "Living Room", host: "living-room.local", port: 49152,
            properties: ["uniqueidentifier": "abc-123", "name": "Living Room"]
        )
        let companion = ResolvedService(
            kind: .companion, name: "Living Room", host: "living-room.local", port: 49153,
            properties: ["rpmrtid": "abc-123", "rpmd": "J255AP"]
        )

        var agg = DeviceAggregator()
        agg.add(mrp)
        agg.add(companion)

        let device = agg.build()
        expect(device != nil, "aggregation result is non-nil")
        if let device {
            expectEqual(device.identifier, "abc-123", "identifier")
            expectEqual(device.name, "Living Room", "name taken from MRP's Name")
            expectEqual(device.model, "Apple TV 4K (3rd Generation)", "model mapped from rpmd")
            expectEqual(device.mrpPort, 49152, "MRP port")
            expectEqual(device.companionPort, 49153, "Companion port")
            expect(device.isMRPSupported, "MRP supported")
            expect(device.isCompanionSupported, "Companion supported")
        }
    }

    runSuite("model mapping") {
        expectEqual(DeviceModel.lookup("J255AP").rawValue, "Apple TV 4K (3rd Generation)", "J255AP")
        expectEqual(DeviceModel.lookup("J305AP").rawValue, "Apple TV 4K (2nd Generation)", "J305AP")
        expectEqual(DeviceModel.lookup("J105aAP").rawValue, "Apple TV 4K (1st Generation)", "J105aAP")
        expectEqual(DeviceModel.lookup("nonexistent").rawValue, "Unknown Device", "unknown model")
    }
}
