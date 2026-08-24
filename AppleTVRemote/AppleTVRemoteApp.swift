import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard isFirstInstance() else { return }
        ATVBridge.shared?.autoConnectIfNeeded()
    }

    /// 检测是否已有本应用实例在运行；若有则激活旧实例并退出，避免菜单栏出现两个图标。
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
            Label("Apple TV 遥控器", systemImage: "av.remote")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(bridge)
        }
    }
}
