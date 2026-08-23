import SwiftUI

struct RemoteView: View {
    @EnvironmentObject private var bridge: ATVBridge
    @Environment(\.openSettings) private var openSettings
    @State private var keyMonitor: PanelKeyMonitor?
    @State private var pressedKey: RemoteKey?

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
                Text("首次使用：打开设置 → 扫描 → 配对\n键盘：方向键移动 · 回车确认 · Esc 返回")
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
            // 面板打开期间挂载键盘监听；关闭时自动移除，不影响其他窗口。
            keyMonitor = PanelKeyMonitor { key in
                guard bridge.connectionState == .connected else { return }
                flashPressed(key)
                Task { await bridge.sendKey(key) }
            }
            if bridge.currentDevice != nil && bridge.apps.isEmpty {
                Task { await bridge.loadApps() }
            }
        }
        .onDisappear {
            keyMonitor = nil
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

    /// 键盘按键时短暂高亮对应按钮，提供视觉反馈。
    private func flashPressed(_ key: RemoteKey) {
        pressedKey = key
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if pressedKey == key { pressedKey = nil }
        }
    }

    private func keyBackground(_ key: RemoteKey) -> Color {
        pressedKey == key ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.08)
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
        .background(keyBackground(key), in: RoundedRectangle(cornerRadius: 8))
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
        .background(keyBackground(key), in: RoundedRectangle(cornerRadius: 8))
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

/// 在面板打开期间监听键盘事件（方向键 / 回车 / Esc），映射为 Apple TV 遥控按键。
/// 事件被消费（返回 nil），避免焦点系统或默认 Esc 关闭行为干扰。
final class PanelKeyMonitor {
    private var token: Any?
    private let onKey: (RemoteKey) -> Void

    init(onKey: @escaping (RemoteKey) -> Void) {
        self.onKey = onKey
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handle(event) else { return event }
            return nil
        }
    }

    deinit {
        if let token {
            NSEvent.removeMonitor(token)
        }
    }

    /// 返回 true 表示事件已被消费。
    private func handle(_ event: NSEvent) -> Bool {
        // 仅当焦点在菜单栏弹窗(类为 NSPanel)时拦截；设置窗口里的输入框不受影响。
        guard NSApp.keyWindow?.isKind(of: NSPanel.self) == true,
              // 忽略自动重复：桥接后端请求会排队，按住不放会造成按键堆积、松手后还在动。
              !event.isARepeat,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        else { return false }

        let key: RemoteKey? = switch event.keyCode {
        case 123: .left
        case 124: .right
        case 125: .down
        case 126: .up
        case 36, 76: .select   // 回车 / 小键盘回车
        case 53: .menu         // Esc = 返回
        default: nil
        }
        guard let key else { return false }
        onKey(key)
        return true
    }
}
