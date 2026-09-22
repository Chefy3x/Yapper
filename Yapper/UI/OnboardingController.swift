import AppKit
import SwiftUI
import Combine

/// Owns the first-run guide's window and decides whether it should appear at all.
///
/// Yapper is an accessory app with no Dock icon, so the guide is also the only moment the app
/// gets to say "here is where I live" before it disappears into the menu bar.
@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    private weak var state: AppState?
    private let isFirstRun: Bool
    private var window: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    /// - Parameter isFirstRun: sampled by the app delegate *before* anything can write to
    ///   UserDefaults, since the probe is "has this app ever persisted anything".
    init(state: AppState, isFirstRun: Bool) {
        self.state = state
        self.isFirstRun = isFirstRun
        super.init()

        // Settings → Hotkeys can ask for the guide back, mirroring `pendingHistoryOpen`.
        state.$pendingOnboardingOpen
            .filter { $0 }
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.state?.pendingOnboardingOpen = false
                    self?.show()
                }
            }
            .store(in: &cancellables)
    }

    func showIfNeeded() {
        guard let state else { return }
        guard !state.settings.onboardingCompleted else { return }

        // Upgrading into this version isn't a first run. Someone who already uses Yapper should
        // not be handed a setup wizard — adopt them as done and stay out of the way.
        guard isFirstRun else {
            Log.app.info("Onboarding suppressed — existing install adopted as complete.")
            state.settings.onboardingCompleted = true
            return
        }

        Log.app.info("First run — showing onboarding.")
        show()
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let state else { return }

        let root = OnboardingView(onFinish: { [weak self] in self?.close() })
            .environmentObject(state)
            .environmentObject(state.settings)

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 620),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = "Set up Yapper"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false          // the controller owns the lifetime
        w.contentView = NSHostingView(rootView: root)
        w.delegate = self
        w.center()

        window = w
        // An accessory app has to ask for activation explicitly, or the window opens behind
        // whatever the user was doing — and the drill needs key-window focus to hold a selection.
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.close()   // windowWillClose records completion
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Dismissing by any route — Done, Skip, or the red button — counts as seen. Re-nagging
        // someone who closed it would be worse than the discoverability gap it's fixing; the
        // guide stays reachable from Settings → Hotkeys.
        state?.settings.onboardingCompleted = true
        window = nil
    }
}
