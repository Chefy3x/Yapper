import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var updater = UpdaterService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "person.wave.2.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Voice").font(.caption).foregroundStyle(.secondary)
                    Text(state.activeVoice.displayName).font(.headline)
                }
                Spacer()
                Circle()
                    .fill(state.hasAccessibilityPermission ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                    .help(state.hasAccessibilityPermission ? "Accessibility granted" : "Accessibility NOT granted — hotkeys won't work")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .onAppear { state.refreshPermissionState() }

            Divider()

            Toggle(isOn: $state.conversationModeEnabled) {
                Label("Conversation Mode", systemImage: "bubble.left.and.bubble.right")
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 12)

            if !state.hasAccessibilityPermission {
                Divider()
                Button {
                    // Bootstrap already registered Yapper in the Accessibility list (the system
                    // prompt fires once); deep-linking to the pane is the reliable repeat action.
                    // The poller picks up the grant within seconds — no relaunch needed.
                    AccessibilityPermission.openSystemSettings()
                } label: {
                    Label("Grant Accessibility Permission", systemImage: "exclamationmark.shield")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
            }

            if !state.lastEvent.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last event").font(.caption2).foregroundStyle(.secondary)
                    Text(state.lastEvent).font(.callout)
                }
                .padding(.horizontal, 12)
            }

            Divider()

            Button {
                state.pendingHistoryOpen = true
                openSettingsWindow()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)

            Button {
                openSettingsWindow()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Settings…", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)

            Button {
                updater.checkForUpdates()
            } label: {
                Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(!updater.canCheckForUpdates)
            .padding(.horizontal, 12)

            Divider()

            Button(role: .destructive) {
                NSApp.terminate(nil)
            } label: {
                Label("Quit Yapper", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .frame(width: 260)
    }

    /// Opens the Settings scene. `@Environment(\.openSettings)` is macOS 14+,
    /// so use the AppKit action that works back to Ventura (which renamed
    /// "Preferences" to "Settings", hence the `showSettingsWindow:` selector).
    private func openSettingsWindow() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
