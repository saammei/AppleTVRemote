import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var bridge: ATVBridge

    var body: some View {
        TabView {
            DeviceSettingsView()
                .environmentObject(bridge)
                .tabItem { Label("Devices", systemImage: "tv") }
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
                    Text("Apple TV Remote")
                        .font(.title2.bold())
                    Text(bridge.connectionState == .connected
                         ? "Connected: \(bridge.currentDevice?.name ?? "")"
                         : "Scan and pair your Apple TV on the local network")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Scan") {
                    Task { await bridge.scanDevices() }
                }
                .disabled(bridge.isScanning)

                if bridge.currentDevice != nil {
                    Button("Disconnect") {
                        Task { await bridge.disconnect() }
                    }
                }
            }

            if bridge.isScanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning local network…").font(.caption)
                }
            }

            if let error = bridge.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if let scanError = bridge.scanError {
                Text(scanError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if bridge.devices.isEmpty {
                VStack(spacing: 14) {
                    ContentUnavailableView(
                        "No Apple TV found",
                        systemImage: "tv.slash",
                        description: Text(bridge.localNetworkDenied
                             ? "This app does not have Local Network permission, so it cannot scan the network."
                             : "Make sure the Apple TV is on and on the same local network, then click Scan.")
                    )
                    // On macOS 15+, if the user previously denied Local Network permission,
                    // the system will not prompt again; users must be guided to enable it
                    // manually in System Settings.
                    Button {
                        openLocalNetworkSettings()
                    } label: {
                        Label("Open Local Network Settings", systemImage: "lock.shield")
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                List(bridge.devices) { device in
                    deviceRow(device)
                }
                .listStyle(.inset)
            }

            Text("Pairing: click Pair, then enter the 4-digit PIN shown on your Apple TV screen. Pairing is only needed once.")
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

    /// Opens the Privacy & Security → Local Network settings pane (macOS 15+).
    private func openLocalNetworkSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LocalNetwork-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
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
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                if pairingDeviceID == device.identifier && bridge.pairingAwaitingPin {
                    HStack {
                        TextField("PIN", text: $pin)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        Button("Confirm") {
                            Task {
                                await bridge.pairFinish(pin: pin)
                                pin = ""
                                pairingDeviceID = nil
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Cancel") {
                            bridge.pairCancel()
                            pin = ""
                            pairingDeviceID = nil
                        }
                    }
                } else {
                    Button("Pair") {
                        pairingDeviceID = device.identifier
                        Task { await bridge.pairBegin(device: device) }
                    }
                    .disabled(bridge.isPairing)
                    Button("Connect") {
                        Task { await bridge.connect(device: device) }
                    }
                    .disabled(bridge.isPairing)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
