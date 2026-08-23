import SwiftUI

struct RemoteView: View {
    @EnvironmentObject private var bridge: ATVBridge
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 14) {
            header
            if let nowPlaying = bridge.nowPlaying, nowPlaying.title != nil {
                nowPlayingRow(nowPlaying)
            }
            dPad
            actionRow
            volumeAndUtilityRow
            if let error = bridge.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            Divider()
            HStack {
                Text("首次使用：打开设置 → 扫描 → 配对")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("退出") {
                    bridge.stop()
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .help("退出应用")
            }
        }
        .padding(16)
        .frame(width: 330)
        .onAppear {
            if bridge.currentDevice != nil && bridge.apps.isEmpty {
                Task { await bridge.loadApps() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(bridge.currentDevice?.name ?? "未连接 Apple TV")
                    .font(.headline)
                    .lineLimit(1)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("设置")
        }
    }

    private var statusColor: Color {
        switch bridge.connectionState {
        case .connected: .green
        case .failed: .red
        case .connecting: .yellow
        case .disconnected: .gray
        }
    }

    private var statusText: String {
        switch bridge.connectionState {
        case .connected:
            let power = bridge.nowPlaying?.powerState.map { " · \($0)" } ?? ""
            return "已连接\(power)"
        case .connecting:
            return "连接中…"
        case .failed(let message):
            return message
        case .disconnected:
            return "未连接"
        }
    }

    private func nowPlayingRow(_ nowPlaying: NowPlaying) -> some View {
        HStack(spacing: 10) {
            if let data = nowPlaying.artwork, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 48, height: 48)
                    .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(nowPlaying.title ?? "—")
                    .font(.headline)
                    .lineLimit(1)
                Text([nowPlaying.artist, nowPlaying.album].compactMap { $0 }.joined(separator: " — "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let position = nowPlaying.position,
                   let total = nowPlaying.totalTime,
                   total > 0 {
                    ProgressView(value: min(position, total), total: total)
                        .frame(width: 170)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var dPad: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                spacer
                keyButton(.up)
                spacer
            }
            HStack(spacing: 6) {
                keyButton(.left)
                keyButton(.select)
                keyButton(.right)
            }
            HStack(spacing: 6) {
                spacer
                keyButton(.down)
                spacer
            }
        }
    }

    private var spacer: some View {
        Color.clear.frame(width: 46, height: 46)
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            keyButton(.menu, label: "菜单")
            iconButton("house.fill", help: "主屏幕", action: { Task { await bridge.sendKey(.home) } })
            iconButton("backward.end.fill", help: "上一个", action: { Task { await bridge.sendKey(.previous) } })
            iconButton("playpause.fill", help: "播放/暂停", action: { Task { await bridge.sendKey(.playPause) } })
            iconButton("forward.end.fill", help: "下一个", action: { Task { await bridge.sendKey(.next) } })
        }
    }

    private var volumeAndUtilityRow: some View {
        HStack(spacing: 8) {
            iconButton("speaker.minus.fill", help: "音量减", action: { Task { await bridge.volume("down") } })
            iconButton("speaker.plus.fill", help: "音量加", action: { Task { await bridge.volume("up") } })

            Menu {
                if bridge.apps.isEmpty {
                    Text("无应用列表（连接后自动加载）")
                }
                ForEach(bridge.apps) { app in
                    Button(app.name) {
                        Task { await bridge.launchApp(app.identifier) }
                    }
                }
            } label: {
                Image(systemName: "square.grid.2x2")
                    .frame(width: 40, height: 34)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("启动应用")

            Button {
                let state = bridge.nowPlaying?.powerState
                Task { await bridge.power(state == "On" ? "off" : "on") }
            } label: {
                Image(systemName: "power")
                    .frame(width: 40, height: 34)
            }
            .buttonStyle(.plain)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .help("电源")
        }
    }

    private func keyButton(_ key: RemoteKey) -> some View {
        Button {
            Task { await bridge.sendKey(key) }
        } label: {
            Image(systemName: key.symbol)
                .font(.title3)
                .frame(width: 46, height: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .help(key.rawValue)
    }

    private func keyButton(_ key: RemoteKey, label: String) -> some View {
        Button {
            Task { await bridge.sendKey(key) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: key.symbol)
                Text(label).font(.caption)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .help(key.rawValue)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .help(help)
    }
}
