import Combine
import Sparkle

/// Wraps Sparkle's standard updater so the SwiftUI menu can trigger checks and
/// disable its item while one is in flight. Instantiated once at launch (see
/// AppDelegate) so scheduled background checks run even if the menu never opens.
@MainActor
final class UpdaterService: ObservableObject {
    static let shared = UpdaterService()

    @Published var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController

    private init() {
        // startingUpdater: true begins Sparkle's scheduled checks; on first launch
        // Sparkle asks the user before enabling automatic checking.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
