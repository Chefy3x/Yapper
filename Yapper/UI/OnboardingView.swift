import SwiftUI
import AppKit

/// The first-run guide.
///
/// It exists for one reason: Yapper's entire control surface is a tap on one modifier key, and
/// that is an invented gesture with no affordance anywhere in macOS. A new user can install the
/// app, grant permission, and never once make it speak — not because they missed something
/// obvious, but because there is nothing to miss. So the middle step doesn't *describe* the
/// gesture, it makes the user perform it once against real text and confirms it landed.
///
/// Three steps, no tour: permission (hard gate), the gesture (the teaching moment), voice (the
/// first impression). Conversation Mode, the mini player, and history are all discoverable in
/// Settings and stay out of here.
struct OnboardingView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: SettingsStore

    /// Called on Done or Skip — the controller closes the window and records completion.
    let onFinish: () -> Void

    init(initialStep: Step = .permission, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        _step = State(initialValue: initialStep)
    }

    @State private var step: Step
    @State private var gestureDone = false
    @State private var wrongGestureHint = false
    enum Step: Int, CaseIterable {
        case permission, gesture, voice
    }

    /// Matches the Settings window: the tape identity rides along with the Cassette shell.
    private var skin: SettingsSkin {
        settings.miniPlayerTheme == .cassette ? .tape : .standard
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                Group {
                    switch step {
                    case .permission: permissionStep
                    case .gesture:    gestureStep
                    case .voice:      voiceStep
                    }
                }
                .padding(.horizontal, 34)
                .padding(.top, 4)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            footer
        }
        // Sized so the tallest step (voice + shortcut recap) fits without scrolling.
        .frame(width: 580, height: 620)
        .background(skin == .tape ? AnyShapeStyle(Tape.void) : AnyShapeStyle(Color(nsColor: .windowBackgroundColor)))
        .environment(\.settingsSkin, skin)
        .tint(skin.accent)
        .preferredColorScheme(skin == .tape ? .dark : nil)
        .onAppear { state.refreshPermissionState() }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(spacing: 14) {
            Text(skin == .tape ? "SET UP YAPPER" : "Set up Yapper")
                .font(skin == .tape ? Tape.mono(10, .bold) : .system(size: 10, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Capsule()
                        .fill(s.rawValue <= step.rawValue ? skin.accent : Color.primary.opacity(0.14))
                        .frame(width: s == step ? 22 : 7, height: 7)
                        .animation(.easeOut(duration: 0.2), value: step)
                }
            }
        }
        .padding(.top, 26)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            if step == .permission {
                Button("Skip setup", action: finish)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        step = Step(rawValue: step.rawValue - 1) ?? .permission
                    }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Spacer()

            switch step {
            case .permission:
                Button("Continue") { advance() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!state.hasAccessibilityPermission)
            case .gesture:
                // Never a hard gate: a trackpad-only user or an odd keyboard layout must still be
                // able to reach the end. The label just stops pretending they finished the drill.
                Button(gestureDone ? "Continue" : "Skip this step") { advance() }
                    .keyboardShortcut(.defaultAction)
            case .voice:
                Button("Done", action: finish)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }

    // MARK: - Step 1 · Permission

    private var permissionStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeading(
                icon: "lock.shield",
                title: "Let it read the screen",
                blurb: "macOS gates that behind Accessibility. No permission, no shortcuts."
            )

            OnboardingCard {
                HStack(spacing: 14) {
                    Image(systemName: state.hasAccessibilityPermission ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(state.hasAccessibilityPermission ? skin.okTint : Color.orange)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.hasAccessibilityPermission ? "Accessibility granted" : "Accessibility not granted yet")
                            .font(skin.body(13, .semibold))
                        Text(state.hasAccessibilityPermission
                             ? "Hotkeys are live."
                             : "Find Yapper in the list, flip it on.")
                            .font(skin.body(11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if !state.hasAccessibilityPermission {
                        Button("Open Settings") { AccessibilityPermission.openSystemSettings() }
                    }
                }
                .animation(.easeOut(duration: 0.2), value: state.hasAccessibilityPermission)
            }

            Text("Recorded locally. Nothing leaves the Mac until you add an online voice.")
                .font(skin.body(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Step 2 · The gesture

    private var gestureStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeading(
                icon: "command",
                title: "One key. Five moves.",
                blurb: "\(settings.yapperKey.keycap), on the right of the space bar. The line below is already selected."
            )

            SampleTextBox(text: Self.sampleLine, skin: skin)

            OnboardingCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        MiniKeycap(content: .text(settings.yapperKey.keycap))
                        Text("+").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                        MiniKeycap(content: .text("S"))
                        Text("Hold it, press S")
                            .font(skin.body(12, .medium))
                        Spacer()
                    }

                    Divider().opacity(0.5)

                    if gestureDone {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(skin.okTint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("That's the manual.")
                                    .font(skin.body(12, .semibold))
                                if !state.lastEvent.isEmpty {
                                    Text(state.lastEvent)
                                        .font(skin.body(10.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .transition(.opacity)
                    } else if wrongGestureHint {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle.fill").foregroundStyle(.orange)
                            Text("That was the bare tap. It reads the latest AI reply, and there isn't one here. Hold it, press S.")
                                .font(skin.body(11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .transition(.opacity)
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "ear")
                                .foregroundStyle(.secondary)
                            Text("waiting for the keys")
                                .font(skin.body(11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !state.hasAccessibilityPermission {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Accessibility is off, so the keys won't fire. Back one step.")
                        .font(skin.body(11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onReceive(state.hotkeyFired) { gesture in
            withAnimation(.easeOut(duration: 0.2)) {
                switch gesture {
                case .readSelection:
                    gestureDone = true
                    wrongGestureHint = false
                case .readLatestOrToggle:
                    if !gestureDone { wrongGestureHint = true }
                default:
                    break
                }
            }
        }
    }

    /// Deliberately self-describing: when it works, the sentence the user hears explains what
    /// just happened, so the payoff and the explanation are the same event.
    private static let sampleLine =
        "This is Yapper. Select any text, anywhere, and I'll read it out loud."

    // MARK: - Step 3 · Voice

    private var voiceStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeading(
                icon: "waveform",
                title: "Pick a voice",
                blurb: "Built-in macOS voice: offline, free, flat. ElevenLabs: the one Yapper was built around."
            )

            OnboardingCard {
                VStack(alignment: .leading, spacing: 14) {
                    APIKeyField(provider: .elevenLabs,
                                previewAction: { state.tts.preview(state.activeVoice) })

                    Text("No key? Skip it — the macOS voice takes the mic, free and offline. Settings → Providers has OpenAI and the rest whenever you want them.")
                        .font(skin.body(10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // The parting reference. After this window closes, the menu bar carries the same list.
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Image(systemName: "menubar.arrow.up.rectangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Lives in the menu bar. This list is always up there.")
                        .font(skin.body(11, .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 2)

                ForEach(Array(ShortcutReference.all(yapperKey: settings.yapperKey).enumerated()), id: \.offset) { _, item in
                    ShortcutLine(caps: item.caps, label: item.label, capColumnWidth: 118)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: skin == .tape ? 4 : 12, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        }
    }

    // MARK: - Flow

    private func advance() {
        withAnimation(.easeOut(duration: 0.18)) {
            step = Step(rawValue: step.rawValue + 1) ?? .voice
        }
    }

    private func finish() {
        onFinish()
    }
}

// MARK: - Pieces

private struct StepHeading: View {
    let icon: String
    let title: String
    let blurb: String
    @Environment(\.settingsSkin) private var skin

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(skin.iconTint)
                .frame(width: 36, height: 36)
                .background(Circle().fill(skin.iconChipBG))

            Text(skin == .tape ? title.uppercased() : title)
                .font(skin.display(skin == .tape ? 21 : 20))
                .fixedSize(horizontal: false, vertical: true)

            Text(blurb)
                .font(skin.body(12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 2)
    }
}

private struct OnboardingCard<Content: View>: View {
    @Environment(\.settingsSkin) private var skin
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: skin == .tape ? 4 : 12, style: .continuous)
                    .fill(skin == .tape ? AnyShapeStyle(Tape.panelGradient) : neutralPanelFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: skin == .tape ? 4 : 12, style: .continuous)
                    .strokeBorder(skin == .tape ? Tape.line : Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
}

// MARK: - Sample text

/// Real selected text for the drill, in a real NSTextView.
///
/// It has to be an AppKit text view rather than a SwiftUI `Text`: the read path asks the frontmost
/// app for `kAXSelectedText` on its focused element (falling back to a synthetic ⌘C), and only a
/// genuine text view answers either of those. The text is pre-selected on appear so the drill
/// tests the one thing that's actually novel — the keystroke — instead of the user's ability to
/// drag-select.
private struct SampleTextBox: View {
    let text: String
    let skin: SettingsSkin

    var body: some View {
        // No fixed height: the standard skin fits this on one line, the tape skin's wider
        // monospaced face wraps it to two. The view reports its own laid-out height instead.
        PreselectedTextView(text: text, isTape: skin == .tape)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: skin == .tape ? 4 : 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: skin == .tape ? 4 : 12, style: .continuous)
                    .strokeBorder(skin.accent.opacity(0.35), lineWidth: 1)
            )
    }
}

private struct PreselectedTextView: NSViewRepresentable {
    let text: String
    let isTape: Bool

    func makeNSView(context: Context) -> SelectingTextView {
        let tv = SelectingTextView()
        tv.string = text
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.font = isTape ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                         : NSFont.systemFont(ofSize: 14)
        tv.textColor = .labelColor
        return tv
    }

    func updateNSView(_ nsView: SelectingTextView, context: Context) {
        if nsView.string != text { nsView.string = text }
    }
}

/// Takes first responder and selects itself once it has a window, so the AX focused element
/// carries a selection the moment the user reaches for the keys.
final class SelectingTextView: NSTextView {
    private var hasPreselected = false

    /// Reports the height the text actually occupies at the current width, so SwiftUI can size
    /// the box to one line or two without a hardcoded guess per skin.
    override var intrinsicContentSize: NSSize {
        guard let manager = layoutManager, let container = textContainer else {
            return super.intrinsicContentSize
        }
        container.containerSize = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        return NSSize(width: NSView.noIntrinsicMetric,
                      height: ceil(manager.usedRect(for: container).height))
    }

    override func layout() {
        super.layout()
        invalidateIntrinsicContentSize()   // width changes can add or drop a line
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !hasPreselected else { return }
        hasPreselected = true
        // Deferred: the window isn't key yet during the move, and first responder wouldn't stick.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
            self.setSelectedRange(NSRange(location: 0, length: (self.string as NSString).length))
        }
    }
}
