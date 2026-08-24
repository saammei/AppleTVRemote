import Foundation
import AppleTVControl

/// 构造 TXT record 字节(便于测试)。
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
    runSuite("TXT record 解析") {
        let data = makeTXTRecord([
            "Name": "Living Room",
            "UniqueIdentifier": "abc-123",
            "allowpairing": "yes",
        ])
        let props = parseTXTRecord(data)
        expectEqual(props["Name"], "Living Room", "Name")
        expectEqual(props["UniqueIdentifier"], "abc-123", "UniqueIdentifier")
        expectEqual(props["allowpairing"], "yes", "allowpairing")
    }

    runSuite("服务类型判断") {
        expectEqual(ServiceKind.from(serviceType: "_mediaremotetv._tcp."), .mrp, "MRP 类型")
        expectEqual(ServiceKind.from(serviceType: "_companion-link._tcp."), .companion, "Companion 类型")
        expectEqual(ServiceKind.from(serviceType: "_airplay._tcp."), nil, "未知类型")
    }

    runSuite("设备聚合") {
        let mrp = ResolvedService(
            kind: .mrp, name: "Living Room", host: "living-room.local", port: 49152,
            properties: ["UniqueIdentifier": "abc-123", "Name": "Living Room"]
        )
        let companion = ResolvedService(
            kind: .companion, name: "Living Room", host: "living-room.local", port: 49153,
            properties: ["rpmrtid": "abc-123", "rpmd": "J255AP"]
        )

        var agg = DeviceAggregator()
        agg.add(mrp)
        agg.add(companion)

        let device = agg.build()
        expect(device != nil, "聚合结果非空")
        if let device {
            expectEqual(device.identifier, "abc-123", "identifier")
            expectEqual(device.name, "Living Room", "名称取 MRP 的 Name")
            expectEqual(device.model, "Apple TV 4K (3代)", "model 由 rpmd 映射")
            expectEqual(device.mrpPort, 49152, "MRP 端口")
            expectEqual(device.companionPort, 49153, "Companion 端口")
            expect(device.isMRPSupported, "支持 MRP")
            expect(device.isCompanionSupported, "支持 Companion")
        }
    }

    runSuite("型号映射") {
        expectEqual(DeviceModel.lookup("J255AP").rawValue, "Apple TV 4K (3代)", "J255AP")
        expectEqual(DeviceModel.lookup("J305AP").rawValue, "Apple TV 4K (2代)", "J305AP")
        expectEqual(DeviceModel.lookup("J105aAP").rawValue, "Apple TV 4K (1代)", "J105aAP")
        expectEqual(DeviceModel.lookup("不存在").rawValue, "未知设备", "未知型号")
    }
}
