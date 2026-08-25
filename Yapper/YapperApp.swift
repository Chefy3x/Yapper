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
    private var onboarding: OnboardingController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Sampled first, before bootstrap or any store can persist a default: the probe for a
        // fresh install is "has Yapper ever written a preference".
        let isFirstRun = SettingsStore.looksLikeFirstRun()

        NSApp.setActivationPolicy(.accessory)
        AppState.shared.bootstrap()
        miniPlayer = MiniPlayerController(state: AppState.shared)
        onboarding = OnboardingController(state: AppState.shared, isFirstRun: isFirstRun)
        onboarding?.showIfNeeded()
        // Start Sparkle's scheduled update checks.
        _ = UpdaterService.shared
    }
}
