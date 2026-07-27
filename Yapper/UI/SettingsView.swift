import SwiftUI
import AppKit

// Brand + Tape tokens and the SettingsSkin environment live in SettingsTheme.swift.

// MARK: - Section model

private enum YSection: String, CaseIterable, Identifiable {
    case general, voices, hotkeys, providers, conversation, history, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general:      "General"
        case .voices:       "Voices"
        case .hotkeys:      "Hotkeys"
        case .providers:    "Providers"
        case .conversation: "Conversation"
        case .history:      "History"
        case .about:        "About"
        }
    }
    var subtitle: String {
        switch self {
        case .general:      "Launch behavior and mini player"
        case .voices:       "Pick your voice or add a custom one"
        case .hotkeys:      "The Right Command contract"
        case .providers:    "ElevenLabs and fallbacks"
        case .conversation: "How Conversation Mode behaves"
        case .history:      "Retention and clearing"
        case .about:        "About Yapper"
        }
    }
    var symbol: String {
        switch self {
        case .general:      "circle.grid.2x2"
        case .voices:       "waveform.circle"
        case .hotkeys:      "command"
        case .providers:    "key"
        case .conversation: "bubble.left.and.bubble.right"
        case .history:      "clock.arrow.circlepath"
        case .about:        "sparkles"
        }
    }
}

// MARK: - Root

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: SettingsStore
    @State private var selected: YSection = .general

    /// The window wears the tape-label identity whenever the Cassette shell is on.
    private var skin: SettingsSkin {
        settings.miniPlayerTheme == .cassette ? .tape : .standard
    }

    var body: some View {
        HStack(spacing: 0) {
            SidebarRail(selected: $selected)
                .frame(width: Brand.railWidth)
                .background(SidebarBackground())

            Divider()
                .overlay(Color.primary.opacity(0.06))

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(section: selected)
                        .padding(.top, 16)
                        .padding(.bottom, 28)

                    content
                        .padding(.bottom, 60)
                }
                .frame(maxWidth: Brand.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 40)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: 12)   // tiny breath under title bar
            }
            .background(ContentBackground())
        }
        .frame(minWidth: 760, minHeight: 580)
        .background(WindowChrome(skin: skin))
        .environment(\.settingsSkin, skin)
        .tint(skin.accent)
        .preferredColorScheme(skin == .tape ? .dark : nil)
        .onAppear {
            if state.pendingHistoryOpen { selected = .history; state.pendingHistoryOpen = false }
        }
        .onChange(of: state.pendingHistoryOpen) { open in
            if open { selected = .history; state.pendingHistoryOpen = false }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selected {
        case .general:      GeneralPanel()
        case .voices:       VoicesPanel()
        case .hotkeys:      HotkeysPanel()
        case .providers:    ProvidersPanel()
        case .conversation: ConversationPanel()
        case .history:      HistoryPanel()
        case .about:        AboutPanel()
        }
    }
}

// MARK: - Window chrome

/// Reaches the hosting NSWindow to strip the title bar — the "Yapper Settings"
/// strip macOS puts on a Settings scene — and ground the window in the skin so
/// there's no pale strip above it. The traffic lights stay, and the top edge
/// remains draggable through the transparent title bar, so the window still moves.
private struct WindowChrome: NSViewRepresentable {
    let skin: SettingsSkin

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in apply(to: view?.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in apply(to: nsView?.window) }
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.backgroundColor = skin == .tape
            ? NSColor(red: 0.063, green: 0.063, blue: 0.063, alpha: 1)   // Tape.void, neutral near-black
            : .windowBackgroundColor
    }
}

// MARK: - Backgrounds

private struct SidebarBackground: View {
    @Environment(\.settingsSkin) private var skin
    var body: some View {
        ZStack {
            if skin == .tape {
                Tape.panelGradient
            } else {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(
                    colors: [
                        Brand.blue.opacity(0.10),
                        Brand.blue.opacity(0.02),
                        .clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
    }
}

private struct ContentBackground: View {
    @Environment(\.settingsSkin) private var skin
    var body: some View {
        ZStack(alignment: skin == .tape ? .top : .topTrailing) {
            if skin == .tape {
                Rectangle().fill(Tape.void)
                // Faint neutral lift near the top — a little depth, no warm wash.
                Circle()
                    .fill(Color.white.opacity(0.02))
                    .frame(width: 640, height: 640)
                    .blur(radius: 140)
                    .offset(y: -300)
            } else {
                Rectangle().fill(.background)
                // Subtle brand-tinted halo in the corner
                Circle()
                    .fill(Brand.blue.opacity(0.10))
                    .frame(width: 520, height: 520)
                    .blur(radius: 120)
                    .offset(x: 200, y: -240)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Sidebar Rail

private struct SidebarRail: View {
    @Binding var selected: YSection
    @Environment(\.settingsSkin) private var skin

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brand mark
            HStack(spacing: 10) {
                YapperGlyph(size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(skin == .tape ? "YAPPER" : "Yapper")
                        .font(skin == .tape ? Tape.shout(17) : .system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(skin == .tape ? Tape.cream : .primary)
                    Text("reads aloud")
                        .font(skin.body(10, .medium))
                        .foregroundStyle(.secondary)
                        .tracking(0.6)
                        .textCase(.uppercase)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 34)   // clears the traffic lights now that the title bar is hidden
            .padding(.bottom, 28)

            // Section nav
            VStack(alignment: .leading, spacing: 2) {
                ForEach(YSection.allCases) { section in
                    SidebarItem(
                        section: section,
                        isSelected: selected == section,
                        action: { selected = section }
                    )
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            // Footer
            VStack(alignment: .leading, spacing: 6) {
                if skin == .tape {
                    TapeBarcode(height: 14)
                }
                Text(skin == .tape ? "V\(appVersion) · SIDE A" : "Version \(appVersion)")
                    .font(skin.body(10, .medium))
                    .tracking(skin == .tape ? 1.2 : 0)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
    }
}

private struct SidebarItem: View {
    let section: YSection
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.settingsSkin) private var skin

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                // Tape skin: the selected row gets a paper tick on the leading edge.
                if skin == .tape {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(isSelected ? Tape.yellow : .clear)
                        .frame(width: 3, height: 14)
                }
                Image(systemName: section.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? skin.accent : Color.primary.opacity(0.65))
                Text(skin == .tape ? section.title.uppercased() : section.title)
                    .font(skin == .tape
                          ? Tape.mono(11.5, isSelected ? .bold : .semibold)
                          : .system(size: 13, weight: isSelected ? .semibold : .medium))
                    .tracking(skin == .tape ? 1.2 : 0)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.primary.opacity(0.80)))
                Spacer()
                if isSelected && skin == .standard {
                    Circle()
                        .fill(Brand.blue)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: skin == .tape ? 3 : 8, style: .continuous)
                    .fill(isSelected
                          ? (skin == .tape ? Color.white.opacity(0.05) : Brand.blueSoft)
                          : (hovering ? Color.primary.opacity(0.05) : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: skin == .tape ? 3 : 8, style: .continuous)
                    .strokeBorder(isSelected && skin == .standard ? Brand.blue.opacity(0.25) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Section header

private struct SectionHeader: View {
    let section: YSection
    @Environment(\.settingsSkin) private var skin

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if skin == .tape {
                // Handwritten eyebrow, like the label annotations.
                Text(section.title.lowercased())
                    .font(Tape.marker(15))
                    .foregroundStyle(Tape.yellow)
                    .rotationEffect(.degrees(-1), anchor: .bottomLeading)
                Text(section.subtitle.uppercased())
                    .font(Tape.shout(27))
                    .foregroundStyle(Tape.cream)
                    .shadow(color: .black.opacity(0.55), radius: 0, y: 2)
            } else {
                Text(section.title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(2.5)
                    .foregroundStyle(Brand.blue)
                Text(section.subtitle)
                    .font(.system(size: 26, weight: .bold, design: .default))
                    .foregroundStyle(.primary)
            }
        }
    }
}

// MARK: - Shared building blocks

private struct Card<Content: View>: View {
    @Environment(\.settingsSkin) private var skin
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: skin == .tape ? 4 : 14, style: .continuous)
                .fill(skin == .tape ? AnyShapeStyle(Tape.panelGradient) : neutralPanelFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: skin == .tape ? 4 : 14, style: .continuous)
                .strokeBorder(skin == .tape ? Tape.line : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(skin == .tape ? 0.45 : 0.04),
                radius: skin == .tape ? 18 : 8, y: skin == .tape ? 8 : 2)
    }
}

private struct RowLabel: View {
    let title: String
    let subtitle: String?
    @Environment(\.settingsSkin) private var skin
    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(skin.body(skin == .tape ? 12.5 : 13, .semibold))
            if let subtitle {
                Text(subtitle)
                    .font(skin.body(11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct RowDivider: View {
    @Environment(\.settingsSkin) private var skin
    var body: some View {
        Group {
            if skin == .tape {
                DashedHairline()
            } else {
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 1)
            }
        }
        .padding(.vertical, 14)
    }
}

private struct SectionLabel: View {
    let text: String
    @Environment(\.settingsSkin) private var skin
    var body: some View {
        Text(text.uppercased())
            .font(skin.body(10, skin == .tape ? .bold : .semibold))
            .tracking(1.6)
            .foregroundStyle(.secondary)
            .padding(.bottom, 10)
    }
}

// MARK: - Yapper logo glyph

private struct YapperGlyph: View {
    var size: CGFloat = 40
    @Environment(\.settingsSkin) private var skin

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * (skin == .tape ? 0.12 : 0.28), style: .continuous)
                .fill(
                    skin == .tape
                    ? LinearGradient(colors: [Tape.yellowHi, Tape.yellowLo],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)
                    : LinearGradient(colors: [Brand.blue, Brand.blueDeep],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .shadow(color: skin == .tape ? .black.opacity(0.5) : Brand.blue.opacity(0.45),
                        radius: size * (skin == .tape ? 0.08 : 0.18), y: size * 0.06)

            // Waveform bars
            HStack(spacing: size * 0.06) {
                bar(0.45)
                bar(0.80)
                bar(0.30)
                bar(0.65)
            }
            .frame(width: size * 0.62, height: size * 0.6)
        }
        .frame(width: size, height: size)
    }

    private func bar(_ h: CGFloat) -> some View {
        Capsule()
            .fill(skin == .tape ? Tape.ink : .white)
            .frame(width: size * 0.08, height: size * h)
    }
}

// MARK: - General

private struct GeneralPanel: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.settingsSkin) private var skin
    @State private var launchToggle: Bool = LaunchAtLogin.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card {
                HStack(alignment: .center, spacing: 16) {
                    Image(systemName: "power")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(skin.iconTint)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(skin.iconChipBG))
                    RowLabel("Launch at login",
                             subtitle: "Start Yapper automatically when you sign in.")
                    Spacer()
                    Toggle("", isOn: $launchToggle)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(skin.accent)
                        .onChange(of: launchToggle) { newValue in
                            LaunchAtLogin.setEnabled(newValue)
                            settings.launchAtLogin = newValue
                        }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) {
                        Image(systemName: "macwindow")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(skin.iconTint)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(skin.iconChipBG))
                        RowLabel("Mini player position",
                                 subtitle: "Where the floating player snaps by default.")
                        Spacer()
                    }

                    CornerPicker(selection: $settings.miniPlayerDefaultCorner)
                        .padding(.leading, 50)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) {
                        Image(systemName: "rectangle.on.rectangle.angled")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(skin.iconTint)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(skin.iconChipBG))
                        RowLabel("Mini player theme",
                                 subtitle: skin == .tape
                                    ? "The whole app dresses for the deck."
                                    : "Minimal bar, or the retro cassette deck.")
                        Spacer()
                        Picker("", selection: $settings.miniPlayerTheme) {
                            ForEach(MiniPlayerTheme.allCases) { theme in
                                Text(theme.displayName).tag(theme)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 190)
                    }

                    if settings.miniPlayerTheme == .cassette {
                        RowDivider()
                        HStack(spacing: 14) {
                            RowLabel("Cassette size",
                                     subtitle: "You can also pinch the deck or drag its edges.")
                            Spacer()
                            Slider(value: $settings.cassetteScale, in: SettingsStore.cassetteScaleRange)
                                .frame(width: 180)
                                .tint(skin.accent)
                            Text("\(Int(settings.cassetteScale * 100))%")
                                .font(skin.body(12, .semibold).monospacedDigit())
                                .foregroundStyle(skin.iconTint)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.tertiary)
                Text("If you've dragged the mini player to a custom spot, that wins until you reset.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }
}

private struct CornerPicker: View {
    @Binding var selection: MiniPlayerCorner
    @Environment(\.settingsSkin) private var skin

    var body: some View {
        // 2x2 visual corner picker
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                cell(.topLeft, label: "Top Left")
                cell(.topRight, label: "Top Right")
            }
            HStack(spacing: 8) {
                cell(.bottomLeft, label: "Bottom Left")
                cell(.bottomRight, label: "Bottom Right")
            }
        }
    }

    private func cell(_ corner: MiniPlayerCorner, label: String) -> some View {
        let isOn = selection == corner
        return Button {
            selection = corner
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: alignment(for: corner)) {
                    RoundedRectangle(cornerRadius: skin == .tape ? 3 : 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 38)
                    Capsule()
                        .fill(isOn ? skin.accent : Color.primary.opacity(0.35))
                        .frame(width: 22, height: 8)
                        .padding(6)
                }
                Text(label)
                    .font(skin.body(11, .medium))
                    .foregroundStyle(isOn ? skin.accent : .secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: skin == .tape ? 3 : 10, style: .continuous)
                    .fill(isOn ? skin.selectionFill : Color.primary.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: skin == .tape ? 3 : 10, style: .continuous)
                    .strokeBorder(isOn ? skin.accent : Color.primary.opacity(0.08), lineWidth: isOn ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func alignment(for corner: MiniPlayerCorner) -> Alignment {
        switch corner {
        case .topLeft:     .topLeading
        case .topRight:    .topTrailing
        case .bottomLeft:  .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }
}

// MARK: - Voices

private struct VoicesPanel: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: SettingsStore
    @State private var newVoiceName: String = ""
    @State private var newVoiceID: String = ""

    private var allVoices: [VoicePreset] {
        VoicePreset.presets + settings.customVoices
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Available")
                VStack(spacing: 8) {
                    ForEach(allVoices) { voice in
                        VoiceCard(
                            voice: voice,
                            isActive: state.activeVoice.id == voice.id,
                            onSelect: { state.activeVoice = voice },
                            onPreview: { state.tts.preview(voice) },
                            onDelete: voice.isCustom ? {
                                settings.customVoices.removeAll { $0.id == voice.id }
                            } : nil
                        )
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Add a custom ElevenLabs voice")
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        FieldRow(label: "Display name") {
                            TextField("e.g. Hannah", text: $newVoiceName)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                        }
                        Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
                        FieldRow(label: "Voice ID") {
                            TextField("e.g. 21m00Tcm4TlvDq8ikWAM", text: $newVoiceID)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, design: .monospaced))
                        }

                        HStack {
                            Spacer()
                            PrimaryButton(title: "Add voice", systemImage: "plus") {
                                addVoice()
                            }
                            .disabled(!canAdd)
                            .opacity(canAdd ? 1 : 0.45)
                        }
                        .padding(.top, 2)
                    }
                }
            }
        }
    }

    private var canAdd: Bool {
        !newVoiceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !newVoiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func addVoice() {
        let id = newVoiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = newVoiceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !name.isEmpty else { return }
        settings.customVoices.append(VoicePreset(
            id: "custom-" + id,
            displayName: name,
            provider: .elevenLabs,
            providerVoiceID: id,
            language: "en",
            isCustom: true
        ))
        newVoiceID = ""
        newVoiceName = ""
    }
}

private struct FieldRow<Content: View>: View {
    let label: String
    @Environment(\.settingsSkin) private var skin
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(label)
                .font(skin.body(11, .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct VoiceCard: View {
    let voice: VoicePreset
    let isActive: Bool
    let onSelect: () -> Void
    let onPreview: () -> Void
    let onDelete: (() -> Void)?
    @State private var hovering = false
    @Environment(\.settingsSkin) private var skin

    private var initial: String {
        String(voice.displayName.prefix(1)).uppercased()
    }

    private var accent: Color {
        skin.avatarColor(for: voice.id)
    }

    private var providerLabel: String {
        let base: String
        switch voice.provider {
        case .elevenLabs:  base = "ElevenLabs"
        case .openAI:      base = "OpenAI"
        case .macOSNative: base = "macOS"
        }
        return voice.isCustom ? base + " · Custom" : base
    }

    var body: some View {
        HStack(spacing: 14) {
            // Avatar
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [accent, accent.opacity(0.75)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text(initial)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(skin == .tape ? Tape.ink : .white)
            }
            .frame(width: 40, height: 40)
            .overlay(
                Circle().strokeBorder(skin == .tape ? Tape.ink.opacity(0.35) : .white.opacity(0.2), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(voice.displayName)
                        .font(skin.body(skin == .tape ? 13 : 14, .semibold))
                    if isActive {
                        Text("ACTIVE")
                            .font(skin.body(9, .bold))
                            .tracking(0.8)
                            .foregroundStyle(skin == .tape ? Tape.ink : Brand.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                skin == .tape
                                ? AnyShapeStyle(Tape.yellow)
                                : AnyShapeStyle(Brand.blueSoft),
                                in: RoundedRectangle(cornerRadius: skin == .tape ? 2 : 20)
                            )
                    }
                }
                Text(providerLabel)
                    .font(skin.body(11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Preview button
            Button(action: onPreview) {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(skin == .tape ? Tape.cream : .white)
                    .frame(width: 30, height: 30)
                    .background(
                        Circle().fill(skin == .tape ? AnyShapeStyle(Color.white.opacity(0.09)) : AnyShapeStyle(skin.accent))
                    )
                    .shadow(color: skin == .tape ? .clear : Brand.blue.opacity(0.4),
                            radius: skin == .tape ? 0 : 6, y: 2)
            }
            .buttonStyle(.plain)
            .help("Preview")

            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(
                            Circle().fill(Color.primary.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: skin == .tape ? 4 : 14, style: .continuous)
                .fill(isActive ? AnyShapeStyle(skin.selectionFill) : AnyShapeStyle(hovering ? Color.primary.opacity(0.04) : Color.gray.opacity(0.08)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: skin == .tape ? 4 : 14, style: .continuous)
                .strokeBorder(isActive ? skin.accent : Color.primary.opacity(0.06),
                              lineWidth: isActive ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isActive)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Hotkeys

private struct HotkeysPanel: View {
    @Environment(\.settingsSkin) private var skin
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Right Command modifier")
                        .font(skin.body(skin == .tape ? 13 : 14, .semibold))
                    Text("Tap or chord with the Right ⌘ key to control Yapper without leaving your current app.")
                        .font(skin.body(11))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 8) {
                HotkeyRow(
                    keys: [.named("Right ⌘")],
                    title: "Read latest",
                    subtitle: "Tap reads latest, or pauses/resumes while playing. Double-tap always reads the focused chat."
                )
                HotkeyRow(
                    keys: [.named("Right ⌘"), .letter("S")],
                    title: "Read selection",
                    subtitle: "Speak the currently selected text"
                )
                HotkeyRow(
                    keys: [.named("Right ⌘"), .symbol("return")],
                    title: "Toggle Conversation Mode",
                    subtitle: "Auto-read new assistant messages"
                )
                HotkeyRow(
                    keys: [.named("Right ⌘"), .letter("D")],
                    title: "AX debug dump",
                    subtitle: "Snapshot the accessibility tree to disk"
                )
            }

            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.tertiary)
                Text("Hotkey rebinding arrives in a later slice. The Right ⌘ contract is currently hardcoded.")
                    .font(skin.body(11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
        }
    }
}

private enum KeyCap {
    case named(String)
    case letter(String)
    case symbol(String) // SF Symbol name

    @ViewBuilder
    var view: some View {
        switch self {
        case .named(let s):  KeycapView(content: .text(s, weight: .semibold, monospaced: false), width: nil)
        case .letter(let s): KeycapView(content: .text(s, weight: .bold, monospaced: true), width: 30)
        case .symbol(let s): KeycapView(content: .symbol(s), width: 38)
        }
    }
}

private struct KeycapView: View {
    enum Content {
        case text(String, weight: Font.Weight, monospaced: Bool)
        case symbol(String)
    }
    let content: Content
    let width: CGFloat?
    @Environment(\.settingsSkin) private var skin

    var body: some View {
        Group {
            switch content {
            case .text(let s, let w, let mono):
                Text(s)
                    .font(.system(size: skin == .tape ? 12 : 13, weight: w,
                                  design: mono || skin == .tape ? .monospaced : .default))
            case .symbol(let s):
                Image(systemName: s)
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        // Standard caps are light plastic; tape caps are the deck's dark transport plastic.
        .foregroundStyle(skin == .tape ? Tape.cream.opacity(0.92) : Color.black.opacity(0.78))
        .frame(minWidth: width ?? 0, minHeight: 30)
        .padding(.horizontal, width == nil ? 14 : 0)
        .background(
            RoundedRectangle(cornerRadius: skin == .tape ? 5 : 6, style: .continuous)
                .fill(
                    skin == .tape
                    ? LinearGradient(
                        colors: [Color(red: 0.176, green: 0.165, blue: 0.145),   // #2D2A25
                                 Color(red: 0.102, green: 0.094, blue: 0.082)],  // #1A1815
                        startPoint: .top, endPoint: .bottom)
                    : LinearGradient(
                        colors: [Color.white.opacity(0.95), Color.white.opacity(0.75)],
                        startPoint: .top, endPoint: .bottom)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: skin == .tape ? 5 : 6, style: .continuous)
                .strokeBorder(skin == .tape ? Color.black : Color.black.opacity(0.18),
                              lineWidth: skin == .tape ? 1 : 0.6)
        )
        .overlay(
            // top inner highlight
            RoundedRectangle(cornerRadius: skin == .tape ? 5 : 6, style: .continuous)
                .strokeBorder(Color.white.opacity(skin == .tape ? 0.16 : 0.9), lineWidth: 0.6)
                .blur(radius: 0.4)
                .padding(0.5)
        )
        .shadow(color: .black.opacity(skin == .tape ? 0.5 : 0.18), radius: skin == .tape ? 2 : 0, y: skin == .tape ? 2 : 1)
    }
}

private struct HotkeyRow: View {
    let keys: [KeyCap]
    let title: String
    let subtitle: String
    @Environment(\.settingsSkin) private var skin

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(Array(keys.enumerated()), id: \.offset) { idx, key in
                    if idx > 0 {
                        Text("+")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    key.view
                }
            }
            .padding(.vertical, 4)
            .frame(minWidth: 170, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(skin.body(skin == .tape ? 12.5 : 13, .semibold))
                Text(subtitle)
                    .font(skin.body(11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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

// MARK: - Providers

private struct ProvidersPanel: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.settingsSkin) private var skin
    @State private var elevenLabsKey: String = ""
    @State private var saved: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "ElevenLabs")
                Card {
                    VStack(alignment: .leading, spacing: 16) {
                        // API key
                        HStack(alignment: .center, spacing: 14) {
                            Image(systemName: "key.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(skin.iconTint)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(skin.iconChipBG))

                            VStack(alignment: .leading, spacing: 4) {
                                Text("API key")
                                    .font(skin.body(skin == .tape ? 12.5 : 13, .semibold))
                                SecureField("xi-•••••••••••••••••••••••", text: $elevenLabsKey)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13, design: .monospaced))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(Color.primary.opacity(0.04))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                                    )
                            }
                        }

                        HStack {
                            if saved {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(skin.okTint)
                                    Text("Saved to Keychain")
                                        .font(skin.body(11, .medium))
                                        .foregroundStyle(.secondary)
                                }
                                .transition(.opacity)
                            }
                            Spacer()
                            PrimaryButton(title: "Save key", systemImage: "lock.fill") {
                                state.keychain.set(elevenLabsKey, for: .elevenLabsKey)
                                withAnimation { saved = true }
                            }
                        }

                        Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)

                        // Model selector
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Model")
                                .font(skin.body(skin == .tape ? 12.5 : 13, .semibold))
                            VStack(spacing: 8) {
                                ForEach(ElevenLabsModel.allCases) { model in
                                    ModelOption(
                                        model: model,
                                        isSelected: settings.elevenLabsModelID == model.id,
                                        onSelect: { settings.elevenLabsModelID = model.id }
                                    )
                                }
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Offline fallback")
                Card {
                    HStack(alignment: .center, spacing: 16) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(skin.iconTint)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(skin.iconChipBG))

                        RowLabel("Use macOS native voice when offline",
                                 subtitle: "Falls back to Samantha when ElevenLabs is unreachable.")
                        Spacer()
                        Toggle("", isOn: $settings.useNativeVoiceOffline)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(skin.accent)
                    }
                }
                Text("OpenAI TTS fallback arrives in Slice 5.")
                    .font(skin.body(11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
        .onAppear {
            elevenLabsKey = state.keychain.get(.elevenLabsKey) ?? ""
            saved = false
        }
    }
}

private struct ModelOption: View {
    let model: ElevenLabsModel
    let isSelected: Bool
    let onSelect: () -> Void
    @Environment(\.settingsSkin) private var skin

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? skin.accent : Color.primary.opacity(0.25),
                                      lineWidth: isSelected ? 5 : 1.5)
                        .frame(width: 16, height: 16)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.displayName)
                        .font(skin.body(skin == .tape ? 12.5 : 13, .semibold))
                        .foregroundStyle(.primary)
                    Text("\(model.characterLimit / 1000)k char limit per request")
                        .font(skin.body(11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: skin == .tape ? 3 : 10, style: .continuous)
                    .fill(isSelected ? skin.selectionFill : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: skin == .tape ? 3 : 10, style: .continuous)
                    .strokeBorder(isSelected ? skin.accent.opacity(skin == .tape ? 1 : 0.5) : Color.primary.opacity(0.08),
                                  lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Conversation

private struct ConversationPanel: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.settingsSkin) private var skin

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card {
                HStack(alignment: .center, spacing: 16) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(skin.liveTint)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(skin.liveTint.opacity(0.13)))
                    RowLabel("Conversation Mode on at launch",
                             subtitle: "Yapper starts ready to auto-read new assistant messages.")
                    Spacer()
                    // Conversation Mode is the REC latch — it reads red in tape mode.
                    Toggle("", isOn: $settings.conversationDefaultOn)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(skin.liveTint)
                }
            }

            // Watched-apps allowlist
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 14) {
                        Image(systemName: "app.badge.checkmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(skin.iconTint)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(skin.iconChipBG))
                        RowLabel("Watched apps",
                                 subtitle: "Auto-read new responses from these, even when they're in the background.")
                        Spacer()
                    }
                    .padding(.bottom, 4)

                    ForEach(Array(ConversationPanel.catalog.enumerated()), id: \.element.id) { idx, app in
                        if idx > 0 { RowDivider() }
                        WatchedAppRow(app: app)
                    }
                }
            }

            // Explainer card — in tape skin this is the pane's one paper moment.
            VStack(alignment: .leading, spacing: 10) {
                if skin == .tape {
                    Text("how it works")
                        .font(Tape.marker(15))
                        .foregroundStyle(Tape.recRed)
                        .rotationEffect(.degrees(-1), anchor: .bottomLeading)
                } else {
                    Text("How it works")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
                Text("While on, Yapper watches the apps you've checked and speaks each new assistant response as it finishes — even when that app isn't focused. Browsers are read only when their active tab is an AI site. Toggle anytime with Right ⌘ + Return; skip ahead with Right ⌘ + →.")
                    .font(skin.body(skin == .tape ? 11.5 : 12))
                    .foregroundStyle(skin == .tape ? AnyShapeStyle(Tape.dust) : AnyShapeStyle(.secondary))
                    .lineSpacing(3)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: skin == .tape ? 4 : 14, style: .continuous)
                    .fill(skin == .tape ? AnyShapeStyle(Tape.panelGradient) : AnyShapeStyle(Brand.blueSoft))
            )
            .overlay(
                RoundedRectangle(cornerRadius: skin == .tape ? 4 : 14, style: .continuous)
                    .strokeBorder(skin == .tape ? Tape.line : Brand.blue.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(skin == .tape ? 0.45 : 0), radius: 14, y: 7)
            .rotationEffect(.degrees(skin == .tape ? -0.4 : 0))
        }
    }

    struct ConvWatchApp: Identifiable {
        let id: String        // bundle identifier
        let name: String
        let strategy: String  // shown as the row subtitle when installed
        let isBrowser: Bool
    }

    static let catalog: [ConvWatchApp] = [
        .init(id: "com.anthropic.claudefordesktop", name: "Claude",  strategy: "Native strategy", isBrowser: false),
        .init(id: "com.openai.codex",               name: "Codex",   strategy: "Native strategy", isBrowser: false),
        .init(id: "com.openai.chat",                name: "ChatGPT", strategy: "Best-effort",     isBrowser: false),
        .init(id: "com.google.Chrome",              name: "Chrome",  strategy: "AI tabs only",    isBrowser: true),
        .init(id: "com.apple.Safari",               name: "Safari",  strategy: "AI tabs only",    isBrowser: true),
        .init(id: "company.thebrowser.Browser",     name: "Arc",     strategy: "AI tabs only",    isBrowser: true),
        .init(id: "company.thebrowser.dia",         name: "Dia",     strategy: "AI tabs only",    isBrowser: true),
        .init(id: "com.microsoft.edgemac",          name: "Edge",    strategy: "AI tabs only",    isBrowser: true),
        .init(id: "com.brave.Browser",              name: "Brave",   strategy: "AI tabs only",    isBrowser: true),
        .init(id: "org.mozilla.firefox",            name: "Firefox", strategy: "AI tabs only",    isBrowser: true),
    ]
}

private struct WatchedAppRow: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.settingsSkin) private var skin
    let app: ConversationPanel.ConvWatchApp

    private var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id) != nil
    }
    private var binding: Binding<Bool> {
        Binding(
            get: { settings.conversationAllowlist.contains(app.id) },
            set: { on in
                if on {
                    if !settings.conversationAllowlist.contains(app.id) {
                        settings.conversationAllowlist.append(app.id)
                    }
                } else {
                    settings.conversationAllowlist.removeAll { $0 == app.id }
                }
            }
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: app.isBrowser ? "globe" : "app.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isInstalled ? skin.iconTint : Color.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(skin.body(skin == .tape ? 12.5 : 13, .semibold))
                Text(isInstalled ? app.strategy : "Not installed")
                    .font(skin.body(11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: binding)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(skin.liveTint)
                .disabled(!isInstalled)
        }
    }
}

// MARK: - History

private struct HistoryPanel: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.settingsSkin) private var skin
    @State private var confirmingClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(skin.iconTint)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(skin.iconChipBG))
                        RowLabel("Retention window",
                                 subtitle: "How long Yapper keeps spoken items in history.")
                        Spacer()
                    }

                    RetentionSlider(hours: $settings.historyRetentionHours)
                }
            }

            Card {
                HStack(spacing: 14) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(skin.destructive)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(skin.destructive.opacity(0.12)))
                    RowLabel("Clear history",
                             subtitle: skin == .tape
                                ? "Burn the tape. All spoken items, gone now."
                                : "Permanently delete all spoken items right now.")
                    Spacer()
                    Button(role: .destructive) {
                        confirmingClear = true
                    } label: {
                        Text(skin == .tape ? "CLEAR" : "Clear")
                            .font(skin.body(skin == .tape ? 11 : 12, skin == .tape ? .bold : .semibold))
                            .tracking(skin == .tape ? 1.2 : 0)
                            .foregroundStyle(skin == .tape ? Tape.cream : .white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                skin == .tape
                                ? AnyShapeStyle(Tape.recRed)
                                : AnyShapeStyle(Color.red.gradient),
                                in: RoundedRectangle(cornerRadius: skin == .tape ? 3 : 20, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .confirmationDialog("Clear all history?",
                                        isPresented: $confirmingClear) {
                        Button("Clear history", role: .destructive) {
                            state.history.clearAll()
                        }
                        Button("Cancel", role: .cancel) { }
                    }
                }
            }

            HistoryBrowser(history: state.history,
                           onReplay: { state.replay($0) },
                           onDelete: { state.history.remove($0) })
        }
        .onChange(of: settings.historyRetentionHours) { hrs in
            state.history.prune(retentionHours: hrs)
        }
    }
}

private struct HistoryBrowser: View {
    @ObservedObject var history: HistoryStore
    let onReplay: (HistoryEntry) -> Void
    let onDelete: (HistoryEntry) -> Void
    @Environment(\.settingsSkin) private var skin

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(skin == .tape ? "RECENT — SIDE A" : "RECENT")
                    .font(skin.body(10, skin == .tape ? .bold : .semibold))
                    .tracking(1.6)
                    .foregroundStyle(.secondary)
                Spacer()
                if !history.entries.isEmpty {
                    Text(skin == .tape
                         ? "\(history.entries.count) TRK"
                         : "\(history.entries.count) item\(history.entries.count == 1 ? "" : "s")")
                        .font(skin.body(11, .medium))
                        .foregroundStyle(.tertiary)
                }
            }

            if history.entries.isEmpty {
                emptyState
            } else {
                VStack(spacing: 8) {
                    ForEach(history.entries) { entry in
                        HistoryRow(entry: entry,
                                   onReplay: { onReplay(entry) },
                                   onDelete: { onDelete(entry) })
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("Nothing read yet")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Items you read with Right ⌘ or Right ⌘ + S show up here for quick replay.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let onReplay: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false
    @Environment(\.settingsSkin) private var skin

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.origin.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(skin.iconTint)
                .frame(width: 32, height: 32)
                .background(Circle().fill(skin.iconChipBG))

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.preview)
                    .font(skin.body(skin == .tape ? 12.5 : 13))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Text(entry.sourceApp)
                        .font(skin.body(11, .medium))
                        .foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(relativeTime(entry.createdAt))
                        .font(skin.body(11))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            Button(action: onReplay) {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(skin == .tape ? Tape.cream : .white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(skin == .tape ? AnyShapeStyle(Color.white.opacity(0.09)) : AnyShapeStyle(skin.accent)))
                    .shadow(color: skin == .tape ? .clear : Brand.blue.opacity(0.4),
                            radius: skin == .tape ? 0 : 6, y: 2)
            }
            .buttonStyle(.plain)
            .help("Replay")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("Remove")
            .opacity(hovering ? 1 : 0.55)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.04) : Color.gray.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private func relativeTime(_ date: Date) -> String {
        let secs = Date().timeIntervalSince(date)
        if secs < 60 { return "just now" }
        let mins = Int(secs / 60)
        if mins < 60 { return "\(mins)m ago" }
        let hrs = mins / 60
        if hrs < 24 { return "\(hrs)h ago" }
        return "\(hrs / 24)d ago"
    }
}

private struct RetentionSlider: View {
    @Binding var hours: Int
    @Environment(\.settingsSkin) private var skin

    private var formatted: String {
        if hours < 24 {
            return "\(hours) hour\(hours == 1 ? "" : "s")"
        } else {
            let days = Double(hours) / 24.0
            let rounded = (days * 10).rounded() / 10
            if rounded == rounded.rounded() {
                let n = Int(rounded)
                return "\(n) day\(n == 1 ? "" : "s")"
            } else {
                return String(format: "%.1f days", rounded)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(skin == .tape ? formatted.uppercased() : formatted)
                    .font(skin == .tape
                          ? Tape.shout(28)
                          : .system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(skin.iconTint)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.15), value: hours)
                Spacer()
                Stepper("", value: $hours, in: 1...168)
                    .labelsHidden()
            }

            // Visual track
            GeometryReader { proxy in
                let pct = CGFloat(max(1, hours) - 1) / CGFloat(167)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 6)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [skin.accent, skin.accentDeep],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(6, proxy.size.width * pct), height: 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 6)

            HStack {
                Text("1 hr").font(skin.body(10, .medium)).foregroundStyle(.tertiary)
                Spacer()
                Text(skin == .tape ? "7 days, then the tape burns" : "7 days")
                    .font(skin.body(10, .medium)).foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - About

/// Marketing version from the bundle so release bumps (scripts/release.sh) propagate
/// everywhere the version is shown without touching this file.
let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
/// The macOS version the app is currently running on, e.g. "macOS 14".
let platformVersion = "macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"

/// Neutral (non-tape) panel fill. `.background.secondary` is a hierarchical
/// ShapeStyle level that needs macOS 14; on Ventura fall back to the neutral
/// window background so Settings surfaces stay charcoal.
var neutralPanelFill: AnyShapeStyle {
    if #available(macOS 14, *) {
        return AnyShapeStyle(.background.secondary)
    } else {
        return AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
    }
}

private struct AboutPanel: View {
    @Environment(\.settingsSkin) private var skin

    var body: some View {
        VStack(spacing: 20) {
            // Splash card — in tape skin, the About pane is the mixtape moment.
            VStack(spacing: 20) {
                if skin == .tape, let deck = CassetteAsset.deck {
                    Image(nsImage: deck)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 300)
                        .shadow(color: .black.opacity(0.6), radius: 22, y: 14)
                        .padding(.top, 28)
                } else {
                    YapperGlyph(size: 84)
                        .padding(.top, 28)
                }

                VStack(spacing: 6) {
                    Text(skin == .tape ? "YAPPER" : "Yapper")
                        .font(skin == .tape ? Tape.shout(38) : .system(size: 36, weight: .bold, design: .default))
                        .foregroundStyle(skin == .tape ? Tape.cream : .primary)
                        .shadow(color: .black.opacity(skin == .tape ? 0.55 : 0), radius: 0, y: 2)
                    if skin == .tape {
                        Text("reads aloud. stays out of your way.")
                            .font(Tape.marker(16))
                            .foregroundStyle(Tape.yellow)
                            .rotationEffect(.degrees(-1.2))
                    } else {
                        Text("READS ALOUD. STAYS OUT OF YOUR WAY.")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(2.0)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    InfoPill(label: "VERSION", value: appVersion)
                    InfoPill(label: "PLATFORM", value: platformVersion)
                    if skin == .tape {
                        InfoPill(label: "POSITION", value: "SIDE A")
                    }
                }
                .padding(.top, 4)

                if skin == .tape {
                    TapeBarcode()
                        .padding(.vertical, 2)
                        .padding(.bottom, 28)
                } else {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 60, height: 1)
                        .padding(.vertical, 6)

                    VStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Text("Reads aloud. Stays out of your way.")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, 28)
                }
            }
            .frame(maxWidth: .infinity)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: skin == .tape ? 4 : 20, style: .continuous)
                        .fill(skin == .tape ? AnyShapeStyle(Tape.panelGradient) : neutralPanelFill)
                    if skin == .standard {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Brand.blue.opacity(0.12), .clear],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: skin == .tape ? 4 : 20, style: .continuous)
                    .strokeBorder(skin == .tape ? Tape.line : Color.primary.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: .black.opacity(skin == .tape ? 0.45 : 0), radius: 20, y: 10)

        }
    }
}

private struct InfoPill: View {
    let label: String
    let value: String
    @Environment(\.settingsSkin) private var skin
    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: skin == .tape ? .monospaced : .default))
                .tracking(1.2)
                .foregroundStyle(skin == .tape ? AnyShapeStyle(Tape.dust) : AnyShapeStyle(.secondary))
            Text(value)
                .font(.system(size: 11, weight: skin == .tape ? .bold : .semibold, design: .monospaced))
                .foregroundStyle(skin == .tape ? AnyShapeStyle(Tape.cream) : AnyShapeStyle(.primary))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            // The tape chip's hard shadow is a real shape underneath — never .shadow(),
            // which re-renders the pill's text as a ghost copy.
            ZStack {
                RoundedRectangle(cornerRadius: skin == .tape ? 2 : 20, style: .continuous)
                    .fill(skin == .tape ? AnyShapeStyle(Color.white.opacity(0.05)) : AnyShapeStyle(Color.primary.opacity(0.05)))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: skin == .tape ? 2 : 20, style: .continuous)
                .strokeBorder(skin == .tape ? Tape.line : Color.primary.opacity(0.08),
                              lineWidth: 1)
        )
    }
}

private struct KeepCoMark: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Brand.blue.gradient)
                .frame(width: 8, height: 8)
            Text("KEEPCO")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Buttons

private struct PrimaryButton: View {
    let title: String
    let systemImage: String?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.settingsSkin) private var skin

    init(title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .bold))
                }
                Text(skin == .tape ? title.uppercased() : title)
                    .font(skin.body(skin == .tape ? 11 : 12, skin == .tape ? .bold : .semibold))
                    .tracking(skin == .tape ? 1.2 : 0)
            }
            .foregroundStyle(skin == .tape ? Tape.ink : .white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                // Tape skin: the sticker-chip recipe — paper fill, ink border, and a hard
                // shadow drawn as a real shape underneath (never .shadow(), which
                // re-renders the label text as a ghost copy).
                ZStack {
                    if skin == .tape {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.black.opacity(0.55))
                            .offset(x: 2, y: 2)
                    }
                    RoundedRectangle(cornerRadius: skin == .tape ? 3 : 20, style: .continuous)
                        .fill(skin == .tape
                              ? AnyShapeStyle(Tape.yellow)
                              : AnyShapeStyle(LinearGradient(
                                  colors: [Brand.blue, Brand.blueDeep],
                                  startPoint: .top,
                                  endPoint: .bottom)))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: skin == .tape ? 3 : 20, style: .continuous)
                    .strokeBorder(skin == .tape ? Tape.ink : .white.opacity(0.15),
                                  lineWidth: skin == .tape ? 1.5 : 0.5)
            )
            .shadow(color: skin == .tape ? .clear : Brand.blue.opacity(hovering ? 0.5 : 0.35),
                    radius: skin == .tape ? 0 : (hovering ? 10 : 6),
                    y: skin == .tape ? 0 : 2)
            .scaleEffect(hovering ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
