import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var bridge: ATVBridge

    var body: some View {
        TabView {
            DeviceSettingsView()
                .environmentObject(bridge)
                .tabItem { Label("设备", systemImage: "tv") }
        }
        .frame(width: 580, height: 480)
    }
}

private struct DeviceSettingsView: View {
    @EnvironmentObject private var bridge: ATVBridge
    @State private var pin = ""
    @State private var pairingDeviceID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple TV 遥控器")
                        .font(.title2.bold())
                    Text(bridge.connectionState == .connected
                         ? "已连接：\(bridge.currentDevice?.name ?? "")"
                         : "在局域网中扫描并配对你的 Apple TV")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("扫描设备") {
                    Task { await bridge.scanDevices() }
                }
                .disabled(bridge.isScanning)

                if bridge.currentDevice != nil {
                    Button("断开") {
                        Task { await bridge.disconnect() }
                    }
                }
            }

            if bridge.isScanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在扫描局域网…").font(.caption)
                }
            }

            if let error = bridge.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if bridge.devices.isEmpty {
                ContentUnavailableView(
                    "未发现 Apple TV",
                    systemImage: "tv.slash",
                    description: Text("确认 Apple TV 已开机并在同一局域网，然后点击“扫描设备”。\n若仍找不到，请检查 系统设置 → 隐私与安全性 → 本地网络 是否已允许本应用。")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(bridge.devices) { device in
                    deviceRow(device)
                }
                .listStyle(.inset)
            }

            Text("配对说明：点击“配对”后，Apple TV 屏幕会显示 4 位 PIN 码，在这里输入即可。之后不需要再次配对。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .onAppear {
            if bridge.devices.isEmpty && bridge.currentDevice == nil && !bridge.isScanning {
                Task { await bridge.scanDevices() }
            }
        }
    }

    private func deviceRow(_ device: ATVDevice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "appletv.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.headline)
                Text([device.model, device.address].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if bridge.currentDevice?.identifier == device.identifier {
                Label("已连接", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                if pairingDeviceID == device.identifier && bridge.pairingAwaitingPin {
                    HStack {
                        TextField("PIN 码", text: $pin)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        Button("确认") {
                            Task {
                                await bridge.pairFinish(pin: pin)
                                pin = ""
                                pairingDeviceID = nil
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    Button("配对") {
                        pairingDeviceID = device.identifier
                        Task { await bridge.pairBegin(device: device) }
                    }
                    .disabled(bridge.isPairing)
                    Button("连接") {
                        Task { await bridge.connect(device: device) }
                    }
                    .disabled(bridge.isPairing)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
