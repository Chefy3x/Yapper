import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: SettingsStore
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

            // The Yapper-key contract is undiscoverable by design — tapping a bare modifier is an
            // invented gesture with no affordance anywhere in macOS. This strip is the standing
            // answer to "what were the keys again", so nobody has to dig through Settings for it.
            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Text("SHORTCUTS")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 1)

                ForEach(Array(ShortcutReference.all(yapperKey: settings.yapperKey).enumerated()), id: \.offset) { _, item in
                    ShortcutLine(caps: item.caps, label: item.label)
                }
            }
            .padding(.horizontal, 12)
            // Without Accessibility these keys are inert; showing them at full strength would
            // promise something the app can't currently do.
            .opacity(state.hasAccessibilityPermission ? 1 : 0.4)

            if !state.lastEvent.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last event").font(.caption2).foregroundStyle(.secondary)
                    Text(state.lastEvent).font(.callout)
                }
                .padding(.horizontal, 12)
            }

            Divider()

            // SettingsView sees the flag and jumps to its History tab.
            SettingsButton(prepare: { state.pendingHistoryOpen = true }) {
                Label("History", systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)

            SettingsButton {
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
        .frame(width: 280)   // widened for the shortcut strip's key column + label
    }
}

/// A button that opens the Settings scene and brings it to the front.
///
/// SwiftUI stopped honouring the `showSettingsWindow:` action on macOS 14: it logs "Please use
/// SettingsLink for opening the Settings scene" and opens nothing. So 14+ goes through
/// `openSettings`, and the selector is kept only for Ventura, where it is still the way in.
/// Either way the popover is dismissed explicitly: it stays hanging under the menu bar otherwise.
private struct SettingsButton<Label: View>: View {
    @Environment(\.dismiss) private var dismiss
    private let prepare: @MainActor () -> Void
    private let label: Label

    init(prepare: @escaping @MainActor () -> Void = {}, @ViewBuilder label: () -> Label) {
        self.prepare = prepare
        self.label = label()
    }

    var body: some View {
        if #available(macOS 14, *) {
            OpenSettingsButton(prepare: prepare, label: label)
        } else {
            Button {
                prepare()
                bringYapperForward()
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                dismiss()
            } label: {
                label
            }
        }
    }
}

@available(macOS 14, *)
private struct OpenSettingsButton<Label: View>: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    let prepare: @MainActor () -> Void
    let label: Label

    var body: some View {
        Button {
            prepare()
            bringYapperForward()
            openSettings()
            dismiss()
        } label: {
            label
        }
    }
}

/// Yapper is an accessory app and the popover is a non-activating panel, so whatever app was
/// frontmost stays active through the click and Settings would surface behind it. macOS 14's
/// cooperative `NSApp.activate()` is refused from here, so use the forceful call; at file scope
/// it sits in the macOS 13 availability context, which keeps its 14+ deprecation quiet.
@MainActor
private func bringYapperForward() {
    NSApp.activate(ignoringOtherApps: true)
}
