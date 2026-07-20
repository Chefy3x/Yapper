import SwiftUI

@main
struct YapperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared
    @StateObject private var settings = AppState.shared.settings

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(state)
                .environmentObject(settings)
        } label: {
            MenuBarIcon()
                .environmentObject(state)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .frame(minWidth: 760, minHeight: 580)
                .environmentObject(state)
                .environmentObject(settings)
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var miniPlayer: MiniPlayerController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppState.shared.bootstrap()
        miniPlayer = MiniPlayerController(state: AppState.shared)
    }
}
