import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard isFirstInstance() else { return }
        ATVBridge.shared?.autoConnectIfNeeded()
    }

    /// Detects whether another instance of this app is already running; if so, activates
    /// the existing instance and exits, preventing two icons in the menu bar.
    private func isFirstInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return true }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if let existing = running.first(where: {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }) {
            existing.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApp.terminate(nil)
            return false
        }
        return true
    }
}

@main
struct AppleTVRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var bridge = ATVBridge()

    var body: some Scene {
        MenuBarExtra {
            RemoteView()
                .environmentObject(bridge)
        } label: {
            Label("Apple TV Remote", systemImage: "av.remote")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(bridge)
        }
    }
}
