import SwiftUI
import AppKit

/// The first-run guide.
///
/// It exists for one reason: Yapper's entire control surface is one modifier key, and that is an
/// invented gesture with no affordance anywhere in macOS. A new user can install the app, grant
/// permission, and never once make it speak — not because they missed something obvious, but
/// because there is nothing to miss. So the read-aloud step doesn't *describe* the gesture, it
/// makes the user perform it once against real text and confirms it landed.
///
/// Five steps, no tour: permission (hard gate), side one (the read-aloud drill), side two (Voice
/// In: microphone and the speech model, so the first hold works), voice (the first impression),
/// and the key's whole contract to close on. Conversation Mode, the mini player, history and the
/// dictionary are all in Settings and stay out of here.
///
/// It wears the light Settings look whatever the mini player wears, as Settings does: the
/// cassette stays on the deck.
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
    @State private var gestureHint: GestureHint?
    @State private var keyProvider: KeyedProvider = .elevenLabs

    enum Step: Int, CaseIterable {
        case permission, readAloud, voiceIn, voice, manual
    }

    /// What the drill says when the key did something other than Key + S.
    private enum GestureHint { case tap, hold }

    private let skin: SettingsSkin = .standard

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                Group {
                    switch step {
                    case .permission: permissionStep
                    case .readAloud:  readAloudStep
                    case .voiceIn:    voiceInStep
                    case .voice:      voiceStep
                    case .manual:     manualStep
                    }
                }
                .padding(.horizontal, 36)
                .padding(.top, 6)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            footer
        }
        // Sized so the tallest step (the shortcut recap) fits without scrolling.
        .frame(width: 600, height: 680)
        .foregroundStyle(Brand.ink)
        .background(Brand.canvas.ignoresSafeArea())
        .environment(\.settingsSkin, skin)
        .tint(skin.controlTint)
        .buttonStyle(SoftButtonStyle())
        .preferredColorScheme(.light)
        .onAppear {
            state.refreshPermissionState()
            state.voiceInput.refreshMicrophonePermission()
        }
    }

    // MARK: - Chrome

    /// The Settings page header in small: the dark counter chip, then the eyebrow.
    private var header: some View {
        HStack(spacing: 9) {
            Text(String(format: "%03d", step.rawValue + 1))
                .font(Brand.label(10))
                .tracking(1)
                .foregroundStyle(Brand.blueOnDark)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Brand.lcd))
                .contentTransition(.numericText())
            Text("SET UP YAPPER")
                .font(Brand.label(10.5))
                .tracking(1.5)
                .foregroundStyle(Brand.muted)

            Spacer()

            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Capsule()
                        .fill(s.rawValue <= step.rawValue ? Brand.ink : Brand.lineStrong)
                        .frame(width: s == step ? 22 : 7, height: 7)
                        .animation(.easeOut(duration: 0.2), value: step)
                }
            }
        }
        .padding(.horizontal, 36)
        // The hosting view starts below the title bar, so this only has to clear the traffic lights' row.
        .padding(.top, 18)
        .padding(.bottom, 22)
    }

    private var footer: some View {
        HStack {
            if step == .permission {
                Button("Skip setup", action: finish)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.muted)
            } else {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        step = Step(rawValue: step.rawValue - 1) ?? .permission
                    }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Brand.muted)
            }

            Spacer()

            switch step {
            case .permission:
                Button("Continue") { advance() }
                    .buttonStyle(InkButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!state.hasAccessibilityPermission)
            case .readAloud:
                // Never a hard gate: a trackpad-only user or an odd keyboard layout must still be
                // able to reach the end. The label just stops pretending they finished the drill.
                Button(gestureDone ? "Continue" : "Skip this step") { advance() }
                    .buttonStyle(InkButtonStyle())
                    .keyboardShortcut(.defaultAction)
            case .voiceIn:
                Button(voiceInSettled ? "Continue" : "Skip for now") { advance() }
                    .buttonStyle(InkButtonStyle())
                    .keyboardShortcut(.defaultAction)
            case .voice:
                Button("Continue") { advance() }
                    .buttonStyle(InkButtonStyle())
                    .keyboardShortcut(.defaultAction)
            case .manual:
                Button("Done", action: finish)
                    .buttonStyle(InkButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 16)
        .background(Brand.rail)
        .overlay(alignment: .top) {
            Rectangle().fill(Brand.line).frame(height: 1)
        }
    }

    // MARK: - Step 1 · Permission

    private var permissionStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeading(
                icon: "lock.shield",
                eyebrow: nil,
                title: "Let Yapper see the chat",
                blurb: "macOS keeps that behind Accessibility. It's how Yapper reads the reply, and how it types what you say. No permission, no shortcuts."
            )

            Card(padding: 18) {
                HStack(spacing: 14) {
                    Image(systemName: state.hasAccessibilityPermission ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(state.hasAccessibilityPermission ? skin.okTint : Color.orange)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.hasAccessibilityPermission ? "Accessibility granted" : "Accessibility not granted yet")
                            .font(skin.body(13, .semibold))
                        Text(state.hasAccessibilityPermission
                             ? "The key is live."
                             : "Find Yapper in the list and switch it on.")
                            .font(skin.body(11.5))
                            .foregroundStyle(Brand.muted)
                    }

                    Spacer()

                    if !state.hasAccessibilityPermission {
                        Button("Open Settings") { AccessibilityPermission.openSystemSettings() }
                    }
                }
                .animation(.easeOut(duration: 0.2), value: state.hasAccessibilityPermission)
            }

            Footnote("Nothing leaves your Mac unless you add an online voice, and then only the text it reads.")
        }
    }

    // MARK: - Step 2 · Side one, read aloud

    private var readAloudStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeading(
                icon: "speaker.wave.2",
                eyebrow: "Side one · read aloud",
                title: "Hear it once",
                blurb: "\(keyName) is the Yapper key. The line below is already selected: hold the key and press S."
            )

            SampleTextBox(text: Self.sampleLine)

            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        MiniKeycap(content: .text(settings.yapperKey.keycap))
                        Text("+").font(.system(size: 10, weight: .bold)).foregroundStyle(Brand.faint)
                        MiniKeycap(content: .text("S"))
                        Text("Hold it, press S")
                            .font(skin.body(12.5, .medium))
                        Spacer()
                    }

                    Rectangle().fill(Brand.line).frame(height: 1)

                    if gestureDone {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(skin.okTint)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("That's side one.")
                                    .font(skin.body(12.5, .semibold))
                                Text("Highlight anything, anywhere, and it reads. A bare tap of the key reads the newest reply in the chat you're in; tap again to pause.")
                                    .font(skin.body(11))
                                    .foregroundStyle(Brand.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .transition(.opacity)
                    } else if let gestureHint {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle.fill").foregroundStyle(.orange)
                            Text(gestureHint == .tap
                                 ? "That was a tap. A tap reads the newest AI reply, and there isn't one here. Hold the key, press S."
                                 : "That was a hold, which is Voice In: it's the next step. Here, press S while the key is down.")
                                .font(skin.body(11.5))
                                .foregroundStyle(Brand.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .transition(.opacity)
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "ear")
                                .foregroundStyle(Brand.faint)
                            Text("Waiting for the keys…")
                                .font(skin.body(11.5))
                                .foregroundStyle(Brand.muted)
                        }
                    }
                }
            }

            if !state.hasAccessibilityPermission {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Accessibility is off, so the key won't fire. Go back one step.")
                        .font(skin.body(11.5))
                        .foregroundStyle(Brand.muted)
                }
            }
        }
        .onReceive(state.hotkeyFired) { gesture in
            withAnimation(.easeOut(duration: 0.2)) {
                switch gesture {
                case .readSelection:
                    gestureDone = true
                    gestureHint = nil
                case .readLatestOrToggle:
                    if !gestureDone { gestureHint = .tap }
                case .pushToTalk:
                    if !gestureDone { gestureHint = .hold }
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

    /// Where the key is, for the one key people go looking for. The others are named plainly.
    private var keyName: String {
        settings.yapperKey == .rightOption
            ? "Right ⌥, the Option key right of the space bar,"
            : settings.yapperKey.keycap
    }

    // MARK: - Step 3 · Side two, Voice In

    private var voiceInStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeading(
                icon: "mic",
                eyebrow: "Side two · voice in",
                title: "Talk, and it types",
                blurb: "Hold \(settings.yapperKey.keycap), talk, let go: your words land typed wherever the cursor is. Yapper never presses Return. Sending stays yours."
            )

            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 14) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Brand.blueDeep)
                            .iconTile(Brand.blueSoft, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Voice in")
                                .font(skin.body(13, .semibold))
                            Text("Transcribed on this Mac. Your audio is never uploaded.")
                                .font(skin.body(11.5))
                                .foregroundStyle(Brand.muted)
                        }
                        Spacer()
                        Toggle("", isOn: $settings.voiceInputEnabled)
                            .labelsHidden()
                            .toggleStyle(.ink)
                    }

                    if settings.voiceInputEnabled {
                        RowDivider()
                        microphoneRow
                        RowDivider()
                        speechModelRow
                    }
                }
                .animation(.easeOut(duration: 0.2), value: settings.voiceInputEnabled)
            }

            Footnote(settings.voiceInputEnabled
                     ? "Try it after setup in any text box. Long one? Tap Space mid-hold to lock the mic, and press the key again to finish."
                     : "Voice In stays off, and Yapper never asks for the microphone. Switch it on any time in Settings → Talk.")
        }
    }

    private var microphoneRow: some View {
        HStack(spacing: 14) {
            Image(systemName: state.hasMicrophonePermission ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(state.hasMicrophonePermission ? skin.okTint : Color.orange)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Microphone")
                    .font(skin.body(13, .semibold))
                Text(state.hasMicrophonePermission ? "Access granted." : "Asked once, so Yapper can listen while you hold the key.")
                    .font(skin.body(11.5))
                    .foregroundStyle(Brand.muted)
            }
            Spacer()
            if !state.hasMicrophonePermission {
                Button("Allow") {
                    Task {
                        _ = await MicrophonePermission.request()
                        state.voiceInput.refreshMicrophonePermission()
                        if !state.hasMicrophonePermission { MicrophonePermission.openSystemSettings() }
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: state.hasMicrophonePermission)
    }

    private var speechModelRow: some View {
        let model = state.voiceInput.model
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: state.whisperModelStatus.isReady ? "checkmark.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(state.whisperModelStatus.isReady ? skin.okTint : Brand.muted)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Speech model: \(model.displayName)")
                        .font(skin.body(13, .semibold))
                    Text(speechModelLine(model))
                        .font(skin.body(11.5))
                        .foregroundStyle(Brand.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                switch state.whisperModelStatus {
                case .notDownloaded:
                    Button("Download") { state.voiceInput.downloadModel() }
                case .downloaded:
                    Button("Load") { state.voiceInput.downloadModel() }
                case .failed:
                    Button("Retry") { state.voiceInput.downloadModel() }
                case .loading:
                    ProgressView().controlSize(.small)
                case .downloading, .ready:
                    EmptyView()
                }
            }
            if case .downloading(let progress) = state.whisperModelStatus {
                ProgressView(value: progress)
                    .tint(skin.controlTint)
                    .padding(.leading, 48)
            }
        }
        .animation(.easeOut(duration: 0.2), value: state.whisperModelStatus)
    }

    private func speechModelLine(_ model: WhisperModel) -> String {
        let size = model.approxSize.replacingOccurrences(of: "≈ ", with: "")
        switch state.whisperModelStatus {
        case .notDownloaded:      return "One \(size) download, then it works offline. Keep going while it comes down."
        case .downloaded:         return "On disk. Loads in a moment."
        case .downloading(let p): return "Downloading… \(Int(p * 100))%. Keep going, it finishes on its own."
        case .loading:            return "Loading onto the Neural Engine…"
        case .ready:              return "Ready."
        case .failed(let why):    return "Download failed: \(why)"
        }
    }

    /// Voice In is ready to use, or the user switched it off: either way, nothing left to do here.
    private var voiceInSettled: Bool {
        !settings.voiceInputEnabled
            || (state.hasMicrophonePermission && (state.whisperModelStatus.isReady || state.whisperModelStatus.isBusy))
    }

    // MARK: - Step 4 · Voice

    private var voiceStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeading(
                icon: "waveform",
                eyebrow: nil,
                title: "Pick a voice",
                blurb: "It already talks in the Mac's own voice: free, offline, no account. Add a key for one that sounds like a person."
            )

            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("", selection: $keyProvider) {
                        Text("ElevenLabs").tag(KeyedProvider.elevenLabs)
                        Text("OpenAI").tag(KeyedProvider.openAI)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()

                    APIKeyField(provider: keyProvider,
                                previewAction: { state.tts.preview(state.activeVoice) },
                                onSaved: { useVoice(from: keyProvider) })
                        .id(keyProvider)   // a fresh field per provider, not one carrying the other's state

                    Text("No key? Skip it. More voices, and the models, in Settings → Voices and Providers.")
                        .font(skin.body(11))
                        .foregroundStyle(Brand.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Step 5 · The manual

    /// The parting reference. After this window closes, Settings → Hotkeys carries the same list.
    private var manualStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeading(
                icon: "menubar.arrow.up.rectangle",
                eyebrow: nil,
                title: "One key. That's the manual.",
                blurb: "Yapper lives in the menu bar, with no Dock icon. The whole list lives in Settings → Hotkeys, where you can change any of it."
            )

            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 9) {
                    // Grouped by side of the key: voice in, read aloud, and both at once.
                    ForEach(ShortcutReference.Group.everyday, id: \.self) { group in
                        ShortcutGroupHeading(group.rawValue)
                            .padding(.top, group == .voiceIn ? 0 : 8)
                        ForEach(Array(ShortcutReference.items(in: group, yapperKey: settings.yapperKey).enumerated()),
                                id: \.offset) { _, item in
                            ShortcutLine(caps: item.caps, label: item.label, capColumnWidth: 168)
                        }
                    }
                }
            }
        }
    }

    /// A key that was just saved should be the voice "Hear it" plays. The default preset is an
    /// ElevenLabs voice, so an OpenAI key alone would otherwise go on reading in the Mac's voice.
    private func useVoice(from provider: KeyedProvider) {
        switch provider {
        case .elevenLabs:
            if state.activeVoice.provider != .elevenLabs { state.activeVoice = .defaultPreset }
        case .openAI:
            if state.activeVoice.provider != .openAI,
               let marin = VoicePreset.presets.first(where: { $0.id == "openai-marin" }) {
                state.activeVoice = marin
            }
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
    /// The site's side-one / side-two naming, for the two halves of the key.
    let eyebrow: String?
    let title: String
    let blurb: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Brand.ink.opacity(0.72))
                .iconTile(Brand.surface, size: 38)
                .overlay(
                    RoundedRectangle(cornerRadius: 38 * 0.28, style: .continuous)
                        .strokeBorder(Brand.line, lineWidth: 1)
                )
                .padding(.bottom, 4)

            if let eyebrow {
                Text(eyebrow.uppercased())
                    .font(Brand.label(10))
                    .tracking(1.4)
                    .foregroundStyle(Brand.blueDeep)
            }

            Text(title)
                .font(Brand.display(30))
                .tracking(-0.3)
                .fixedSize(horizontal: false, vertical: true)

            Text(blurb)
                .font(.system(size: 13.5))
                .foregroundStyle(Brand.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 2)
    }
}

private struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Brand.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
    }
}

/// The Settings primary button as a ButtonStyle, so the footer keeps Return as its shortcut.
private struct InkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(configuration.isPressed ? Brand.inkHover : Brand.ink)
                    .shadow(color: Brand.ink.opacity(0.22), radius: 1, y: 1)
            )
            .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5).padding(0.5))
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(Capsule())
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

    var body: some View {
        // No fixed height: the view reports its own laid-out height, one line or two.
        PreselectedTextView(text: text)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: Brand.cardRadius, style: .continuous)
                    .fill(Brand.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Brand.cardRadius, style: .continuous)
                    .strokeBorder(Brand.blue.opacity(0.35), lineWidth: 1)
            )
    }
}

private struct PreselectedTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> SelectingTextView {
        let tv = SelectingTextView()
        tv.string = text
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.font = NSFont.systemFont(ofSize: 14.5)
        tv.textColor = NSColor(Brand.ink)
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
    /// the box to one line or two without a hardcoded guess.
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
