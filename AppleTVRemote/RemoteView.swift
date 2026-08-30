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
                Text("First use: open Settings → Scan → Pair\nKeyboard: arrows to move · Return to select · Esc for back\nSpace play/pause · ⌘↑↓ volume · ⌘←→ track · ⌥←→ skip")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit") {
                    bridge.stop()
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .help("Quit the app")
            }
        }
        .padding(16)
        .frame(width: 330)
        .onAppear {
            // A MenuBarExtra(.window) panel does not activate the app by default and
            // cannot reliably become the key window, so keyboard events (arrows/Return)
            // would not be delivered to this app. Activate the app explicitly when the
            // panel opens and make the panel the key window.
            // Note: macOS 14+ ignores the ignoringOtherApps parameter; use the no-argument version.
            NSApp.activate()
            makePanelKey()

            // Install the keyboard monitor while the panel is open; it is removed automatically on close, without affecting other windows.
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
                Text(bridge.currentDevice?.name ?? "Not connected")
                    .font(.headline)
                    .lineLimit(1)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                toggleSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(PressScaleButtonStyle())
            .help("Show/hide settings")
        }
    }

    /// Makes the menu bar panel the key window. The panel may not be visible yet when it
    /// first opens; retry with a delay if not found, up to 5 times (~0.5 s).
    private func makePanelKey(attempt: Int = 0) {
        DispatchQueue.main.async {
            guard let panel = NSApp.windows.first(where: {
                $0.isKind(of: NSPanel.self) && $0.isVisible
            }) as? NSPanel else {
                guard attempt < 5 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.makePanelKey(attempt: attempt + 1)
                }
                return
            }
            panel.becomesKeyOnlyIfNeeded = false
            panel.makeKey()
        }
    }

    /// Toggles the Settings window: click once to show and bring to front, click again to hide.
    /// In a MenuBarExtra (LSUIElement) app, openSettings does not automatically bring the
    /// window to the front, so the app must be activated and makeKeyAndOrderFront called manually.
    private func toggleSettings() {
        if let window = settingsWindow() {
            if window.isVisible {
                window.orderOut(nil)
            } else {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        } else {
            openSettings()
            // openSettings creates the window asynchronously; wait one beat before bringing it to front
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                self.settingsWindow()?.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// The Settings window is a standard NSWindow; the menu bar popover is an NSPanel, so exclude panels.
    private func settingsWindow() -> NSWindow? {
        NSApp.windows.first { !$0.isKind(of: NSPanel.self) && $0.canBecomeKey }
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
            return "Connected\(power)"
        case .connecting:
            return "Connecting…"
        case .failed(let message):
            return message
        case .disconnected:
            return "Not connected"
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
            keyButton(.menu, label: "Menu")
            iconButton("house.fill", key: .home, help: "Home", action: { Task { await bridge.sendKey(.home) } })
            iconButton("backward.end.fill", key: .previous, help: "Previous", action: { Task { await bridge.sendKey(.previous) } })
            iconButton("playpause.fill", key: .playPause, help: "Play/Pause", action: { Task { await bridge.sendKey(.playPause) } })
            iconButton("forward.end.fill", key: .next, help: "Next", action: { Task { await bridge.sendKey(.next) } })
        }
    }

    private var volumeAndUtilityRow: some View {
        HStack(spacing: 8) {
            iconButton("speaker.minus.fill", key: .volumeDown, help: "Volume Down", action: { Task { await bridge.volume("down") } })
            iconButton("speaker.plus.fill", key: .volumeUp, help: "Volume Up", action: { Task { await bridge.volume("up") } })

            Menu {
                if bridge.apps.isEmpty {
                    Text("No app list (loads after connecting)")
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
            .help("Launch App")

            Button {
                let state = bridge.nowPlaying?.powerState
                Task { await bridge.power(state == "On" ? "off" : "on") }
            } label: {
                Image(systemName: "power")
                    .frame(width: 40, height: 34)
            }
            .buttonStyle(PressScaleButtonStyle())
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .help("Power")
        }
    }

    /// Briefly highlights and shrinks the corresponding button while a key is pressed, for visual feedback.
    private func flashPressed(_ key: RemoteKey) {
        pressedKey = key
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            if pressedKey == key { pressedKey = nil }
        }
    }

    private func keyBackground(_ key: RemoteKey) -> Color {
        pressedKey == key ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.08)
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
        .buttonStyle(PressScaleButtonStyle())
        .background(keyBackground(key), in: RoundedRectangle(cornerRadius: 8))
        .scaleEffect(pressedKey == key ? 0.88 : 1.0)
        .animation(.easeOut(duration: 0.1), value: pressedKey)
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
        .buttonStyle(PressScaleButtonStyle())
        .background(keyBackground(key), in: RoundedRectangle(cornerRadius: 8))
        .scaleEffect(pressedKey == key ? 0.88 : 1.0)
        .animation(.easeOut(duration: 0.1), value: pressedKey)
        .help(key.rawValue)
    }

    private func iconButton(_ symbol: String, key: RemoteKey, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .background(keyBackground(key), in: RoundedRectangle(cornerRadius: 8))
        .scaleEffect(pressedKey == key ? 0.88 : 1.0)
        .animation(.easeOut(duration: 0.1), value: pressedKey)
        .help(help)
    }
}

/// Listens for keyboard events (arrows / Return / Esc) while the panel is open and maps
/// them to Apple TV remote keys. Events are consumed (returning nil) so the focus system
/// or the default Esc-close behavior does not interfere.
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

    /// Returns true if the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        // Only intercept when focus is not in the Settings window (a standard NSWindow).
        // Even if the MenuBarExtra panel cannot become the key window (keyWindow is nil),
        // keyboard events should still be treated as panel-scene; let them through only when
        // the Settings window is key, so controls like the PIN text field are not disturbed.
        if let keyWindow = NSApp.keyWindow, !keyWindow.isKind(of: NSPanel.self) {
            return false
        }
        // Ignore auto-repeat: bridge requests are queued, so holding a key down would pile up presses that keep firing after release.
        guard !event.isARepeat else { return false }

        let flags = event.modifierFlags
        let key: RemoteKey?

        if flags.intersection([.command, .control, .option]).isEmpty {
            key = switch event.keyCode {
            case 49: .playPause        // space = play/pause
            case 123: .left
            case 124: .right
            case 125: .down
            case 126: .up
            case 36, 76: .select       // Return / numeric keypad Return
            case 53: .menu             // Esc = back
            default: nil
            }
        } else if flags.contains(.command), flags.intersection([.control, .option]).isEmpty {
            key = switch event.keyCode {
            case 123: .previous        // ⌘← = previous track
            case 124: .next            // ⌘→ = next track
            case 125: .volumeDown      // ⌘↓ = volume down
            case 126: .volumeUp        // ⌘↑ = volume up
            default: nil
            }
        } else if flags.contains(.option), flags.intersection([.command, .control]).isEmpty {
            key = switch event.keyCode {
            case 123: .skipBackward    // ⌥← = skip back 10 s
            case 124: .skipForward     // ⌥→ = skip forward 10 s
            default: nil
            }
        } else {
            key = nil
        }

        guard let key else { return false }
        onKey(key)
        return true
    }
}

/// A button style that scales down slightly when pressed, so mouse clicks also get press feedback.
struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
