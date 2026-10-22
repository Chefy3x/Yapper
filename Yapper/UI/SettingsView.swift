import SwiftUI
import AppKit

// Brand tokens and the SettingsSkin environment live in SettingsTheme.swift.

// MARK: - Section model

enum YSection: String, CaseIterable, Identifiable {
    case general, hotkeys
    case voiceIn, dictations, dictionary, snippets, models
    case voices, providers, conversation, history
    case about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general:      "General"
        case .hotkeys:      "Hotkeys"
        case .voiceIn:      "Talk"
        case .dictations:   "Dictation history"
        case .dictionary:   "Dictionary"
        case .snippets:     "Snippets"
        case .models:       "Models"
        case .voices:       "Voices"
        case .providers:    "Providers"
        case .conversation: "Conversation"
        case .history:      "Read-aloud history"
        case .about:        "About"
        }
    }
    /// The handwritten eyebrow over the page title, where the sidebar name alone would be vague.
    var eyebrow: String {
        switch self {
        case .voiceIn: "voice in"
        default:       title.lowercased()
        }
    }
    var subtitle: String {
        switch self {
        case .general:      "Launch behavior and mini player"
        case .hotkeys:      "The Yapper key contract"
        case .voiceIn:      "Hold the Yapper key and talk"
        case .dictations:   "Everything you've said, kept on this Mac"
        case .dictionary:   "Words Yapper spells your way"
        case .snippets:     "Say a phrase, type a block of text"
        case .models:       "Speech and formatting, on this Mac"
        case .voices:       "Pick your voice or add a custom one"
        case .providers:    "ElevenLabs and fallbacks"
        case .conversation: "How Conversation Mode behaves"
        case .history:      "Retention and clearing"
        case .about:        "About Yapper"
        }
    }
    var symbol: String {
        switch self {
        case .general:      "circle.grid.2x2"
        case .hotkeys:      "command"
        case .voiceIn:      "mic"
        case .dictations:   "text.bubble"
        case .dictionary:   "character.book.closed"
        case .snippets:     "text.badge.plus"
        case .models:       "cpu"
        case .voices:       "waveform.circle"
        case .providers:    "key"
        case .conversation: "bubble.left.and.bubble.right"
        case .history:      "clock.arrow.circlepath"
        case .about:        "sparkles"
        }
    }

    /// Sidebar groups, in order. A nil heading is drawn without one.
    static let groups: [(heading: String?, sections: [YSection])] = [
        (nil, [.general, .hotkeys]),
        ("Voice in", [.voiceIn, .dictations, .dictionary, .snippets, .models]),
        ("Read aloud", [.voices, .providers, .conversation, .history]),
        (nil, [.about]),
    ]
}

/// Lets a page send the window to another one ("Manage models…").
private struct SettingsNavigateKey: EnvironmentKey {
    static let defaultValue: @Sendable @MainActor (YSection) -> Void = { _ in }
}

extension EnvironmentValues {
    var settingsNavigate: @Sendable @MainActor (YSection) -> Void {
        get { self[SettingsNavigateKey.self] }
        set { self[SettingsNavigateKey.self] = newValue }
    }
}

// MARK: - Root

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: SettingsStore
    @State private var selected: YSection
    private let stores: VoiceInStores

    init(stores: VoiceInStores? = nil, initial: YSection = .general) {
        self.stores = stores ?? .live
        _selected = State(initialValue: initial)
    }

    /// One light look, whatever the mini player wears; the cassette stays on the deck.
    private let skin: SettingsSkin = .standard
    /// Space either side of the page.
    private static let pagePadding: CGFloat = 44

    var body: some View {
        HStack(spacing: 0) {
            SidebarRail(selected: $selected)
                .frame(width: Brand.railWidth)
                .background(Brand.rail.ignoresSafeArea())
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Brand.line).frame(width: 1).ignoresSafeArea()
                }

            // The page grows with the window: past the base column, the cards widen and the type
            // scales up with them (to `Brand.maxScale`), so a bigger window reads bigger instead of
            // leaving the page stranded in one corner.
            GeometryReader { geo in
                let scale = Brand.scale(forContentWidth: geo.size.width - Self.pagePadding * 2)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        SectionHeader(section: selected)
                            .padding(.top, 30)
                            .padding(.bottom, 26)

                        content
                            .padding(.bottom, 60)
                    }
                    .frame(maxWidth: Brand.contentMaxWidth * scale, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Self.pagePadding)
                }
                .environment(\.settingsScale, scale)
            }
            .background(Brand.canvas.ignoresSafeArea())
        }
        .frame(minWidth: 780, maxWidth: .infinity, minHeight: 580, maxHeight: .infinity)
        .foregroundStyle(Brand.ink)
        .background(WindowChrome())
        .environment(\.settingsSkin, skin)
        .environment(\.settingsNavigate, { selected = $0 })
        .tint(skin.controlTint)
        .buttonStyle(SoftButtonStyle())
        .preferredColorScheme(.light)
        .onAppear {
            if let section = state.pendingSettingsSection { selected = section; state.pendingSettingsSection = nil }
        }
        .onChange(of: state.pendingSettingsSection) { section in
            if let section { selected = section; state.pendingSettingsSection = nil }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selected {
        case .general:      GeneralPanel()
        case .hotkeys:      HotkeysPanel()
        case .voiceIn:      VoiceInPanel()
        case .dictations:   DictationsPanel(store: stores.dictations)
        case .dictionary:   DictionaryPanel(vocab: stores.vocabulary)
        case .snippets:     SnippetsPanel(store: stores.snippets)
        case .models:       ModelsPanel()
        case .voices:       VoicesPanel()
        case .providers:    ProvidersPanel()
        case .conversation: ConversationPanel()
        case .history:      HistoryPanel()
        case .about:        AboutPanel()
        }
    }
}

// MARK: - Window chrome

/// Reaches the hosting NSWindow to strip the title bar — the "Yapper Settings"
/// strip macOS puts on a Settings scene — and ground the window in the page colour so
/// there's no strip above it. The traffic lights stay, and the top edge
/// remains draggable through the transparent title bar, so the window still moves.
private struct WindowChrome: NSViewRepresentable {
    /// The size the window opens at: tall enough to show the whole General page without
    /// scrolling. The scene's 780×580 minimum is only the floor for dragging it smaller.
    static let openingSize = NSSize(width: 1000, height: 800)

    final class Coordinator {
        weak var sizedWindow: NSWindow?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak view] in apply(to: view?.window, coordinator) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak nsView] in apply(to: nsView?.window, coordinator) }
    }

    private func apply(to window: NSWindow?, _ coordinator: Coordinator) {
        guard let window else { return }
        if coordinator.sizedWindow !== window {
            coordinator.sizedWindow = window
            growToOpeningSize(window)
        }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        // A Settings scene is created fixed-size; let the user drag it larger.
        window.styleMask.insert(.resizable)
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = NSColor(Brand.canvas)
    }

    /// Grows the window to `openingSize` (never shrinks one the user already made larger),
    /// clamped to the screen's visible area and kept centred on where it was.
    private func growToOpeningSize(_ window: NSWindow) {
        let current = window.frame
        var target = window.frameRect(forContentRect: NSRect(origin: .zero, size: Self.openingSize)).size
        target.width = max(target.width, current.width)
        target.height = max(target.height, current.height)
        guard target != current.size else { return }

        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        if let visible {
            target.width = min(target.width, visible.width)
            target.height = min(target.height, visible.height)
        }
        var frame = NSRect(x: current.midX - target.width / 2, y: current.midY - target.height / 2,
                           width: target.width, height: target.height)
        if let visible {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        window.setFrame(frame, display: true)
    }
}

// MARK: - Sidebar Rail

private struct SidebarRail: View {
    @Binding var selected: YSection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                YapperGlyph(size: 28)
                Text("Yapper")
                    .settingsDisplay(22)
                    .foregroundStyle(Brand.ink)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 40)   // clears the traffic lights now that the title bar is hidden
            .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(YSection.groups.enumerated()), id: \.offset) { index, group in
                    if let heading = group.heading {
                        Text(heading.uppercased())
                            .settingsLabel(9.5)
                            .tracking(1.4)
                            .foregroundStyle(Brand.faint)
                            .padding(.horizontal, 12)
                            .padding(.top, 16)
                            .padding(.bottom, 5)
                    } else if index > 0 {
                        Spacer().frame(height: 14)
                    }
                    ForEach(group.sections) { section in
                        SidebarItem(section: section, isSelected: selected == section) { selected = section }
                    }
                }
            }
            .padding(.horizontal, 12)

            Spacer()

            HStack(spacing: 7) {
                Circle().fill(Brand.led).frame(width: 6, height: 6)
                Text("Version \(appVersion)")
                    .settingsLabel(10)
                    .foregroundStyle(Brand.faint)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
    }
}

private struct SidebarItem: View {
    let section: YSection
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .settingsFont(size: 13, weight: .medium)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Brand.ink : Brand.muted)
                Text(section.title)
                    .settingsFont(size: 13, weight: isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? Brand.ink : Brand.ink.opacity(0.78))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Brand.surface : (hovering ? Brand.ink.opacity(0.045) : .clear))
                    .shadow(color: Brand.ink.opacity(isSelected ? 0.07 : 0), radius: 2, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isSelected ? Brand.line : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Section header

/// The page title, with the site's tape-counter eyebrow above it: a three-digit number
/// on a dark chip, then the group it belongs to.
private struct SectionHeader: View {
    let section: YSection

    private var counter: String {
        let index = (YSection.allCases.firstIndex(of: section) ?? 0) + 1
        return String(format: "%03d", index)
    }

    private var group: String {
        YSection.groups.first { $0.sections.contains(section) }?.heading ?? "Yapper"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Text(counter)
                    .settingsLabel(10)
                    .tracking(1)
                    .foregroundStyle(Brand.blueOnDark)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Brand.lcd))
                Text(group.uppercased())
                    .settingsLabel(10.5)
                    .tracking(1.5)
                    .foregroundStyle(Brand.muted)
            }
            Text(section.title)
                .settingsDisplay(38)
                .tracking(-0.4)
                .foregroundStyle(Brand.ink)
            Text(section.subtitle)
                .settingsFont(size: 14)
                .foregroundStyle(Brand.muted)
        }
    }
}

// MARK: - Shared building blocks

struct Card<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Brand.cardRadius, style: .continuous)
                .fill(Brand.surface)
                .shadow(color: Brand.ink.opacity(0.05), radius: 1, y: 1)
                .shadow(color: Brand.ink.opacity(0.04), radius: 4, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Brand.cardRadius, style: .continuous)
                .strokeBorder(Brand.line, lineWidth: 1)
        )
    }
}

struct RowLabel: View {
    let title: String
    let subtitle: String?
    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .settingsFont(size: 13, weight: .medium)
                .foregroundStyle(Brand.ink)
            if let subtitle {
                Text(subtitle)
                    .settingsFont(size: 12)
                    .foregroundStyle(Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Brand.line)
            .frame(height: 1)
            .padding(.vertical, 14)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .settingsLabel(10.5)
            .tracking(1.4)
            .foregroundStyle(Brand.muted)
            .padding(.bottom, 10)
            .padding(.leading, 2)
    }
}

// MARK: - Yapper logo glyph

/// The app icon in miniature: the megaphone mark in white on a blue tile.
private struct YapperGlyph: View {
    var size: CGFloat = 40

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(Brand.blue)
            .overlay(
                Image("MenuBarMark", bundle: Bundle(for: AppState.self))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.white)
                    .padding(size * 0.2)
            )
            .frame(width: size, height: size)
            .shadow(color: Brand.ink.opacity(0.12), radius: size * 0.04, y: size * 0.02)
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
                        .settingsFont(size: 16, weight: .semibold)
                        .foregroundStyle(skin.iconTint)
                        .iconTile(skin.iconChipBG, size: 34)
                    RowLabel("Launch at login",
                             subtitle: "Start Yapper automatically when you sign in.")
                    Spacer()
                    Toggle("", isOn: $launchToggle)
                        .labelsHidden()
                        .toggleStyle(.ink)
                        .tint(skin.controlTint)
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
                            .settingsFont(size: 16, weight: .semibold)
                            .foregroundStyle(skin.iconTint)
                            .iconTile(skin.iconChipBG, size: 34)
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
                            .settingsFont(size: 16, weight: .semibold)
                            .foregroundStyle(skin.iconTint)
                            .iconTile(skin.iconChipBG, size: 34)
                        RowLabel("Mini player theme",
                                 subtitle: "Minimal bar, or the retro cassette deck.")
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
                                .tint(skin.controlTint)
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
                    .foregroundStyle(Brand.faint)
                Text("If you've dragged the mini player to a custom spot, that wins until you reset.")
                    .settingsFont(size: 11)
                    .foregroundStyle(Brand.muted)
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
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Brand.ink.opacity(0.06))
                        .frame(height: 38)
                    Capsule()
                        .fill(isOn ? skin.accent : Brand.ink.opacity(0.35))
                        .frame(width: 22, height: 8)
                        .padding(6)
                }
                Text(label)
                    .settingsBody(11, .medium)
                    .foregroundStyle(isOn ? skin.accent : .secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isOn ? skin.selectionFill : Brand.ink.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isOn ? skin.accent : Brand.ink.opacity(0.08), lineWidth: isOn ? 1.5 : 1)
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
    @Environment(\.settingsSkin) private var skin
    @State private var newVoiceName: String = ""
    @State private var newVoiceID: String = ""

    private var groups: [(title: String, voices: [VoicePreset])] {
        let all = VoicePreset.presets + settings.customVoices
        return [
            ("ElevenLabs", all.filter { $0.provider == .elevenLabs }),
            ("OpenAI", all.filter { $0.provider == .openAI }),
            ("Built into macOS", all.filter { $0.provider == .macOSNative }),
        ].filter { !$0.voices.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel(text: group.title)
                    ListCard {
                        ForEach(Array(group.voices.enumerated()), id: \.element.id) { idx, voice in
                            VoiceRow(voice: voice,
                                     isActive: state.activeVoice.id == voice.id,
                                     last: idx == group.voices.count - 1,
                                     onSelect: { state.activeVoice = voice },
                                     onPreview: { state.tts.preview(voice) },
                                     onDelete: voice.isCustom ? {
                                         settings.customVoices.removeAll { $0.id == voice.id }
                                     } : nil)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: "Add an ElevenLabs voice")
                Card {
                    HStack(spacing: 10) {
                        TextField("Name", text: $newVoiceName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                        TextField("Voice ID, e.g. 21m00Tcm4TlvDq8ikWAM", text: $newVoiceID)
                            .textFieldStyle(.roundedBorder)
                            .settingsFont(size: 12, design: .monospaced)
                            .onSubmit(addVoice)
                        Button("Add", action: addVoice)
                            .disabled(!canAdd)
                    }
                    Text("In ElevenLabs, open Voices, then the voice's ⋯ menu → Copy voice ID.")
                        .settingsBody(11)
                        .foregroundStyle(Brand.muted)
                        .padding(.top, 10)
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

/// One voice in a provider's list: click the row to use it, ▶ to hear it.
private struct VoiceRow: View {
    let voice: VoicePreset
    let isActive: Bool
    let last: Bool
    let onSelect: () -> Void
    let onPreview: () -> Void
    let onDelete: (() -> Void)?
    @State private var hovering = false
    @Environment(\.settingsSkin) private var skin

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .settingsFont(size: 15, weight: isActive ? .semibold : .regular)
                .foregroundStyle(isActive ? skin.controlTint : Brand.lineStrong)
                .frame(width: 18)
            Text(voice.displayName)
                .settingsBody(13, isActive ? .semibold : .medium)
                .foregroundStyle(Brand.ink)
            if voice.isCustom { TagChip(text: "Custom") }
            if isActive {
                Text("In use")
                    .settingsBody(11)
                    .foregroundStyle(Brand.muted)
            }
            Spacer(minLength: 8)
            RowIconButton(symbol: "play.fill", help: "Preview \(voice.displayName)", action: onPreview)
            if let onDelete {
                RowIconButton(symbol: "trash", help: "Remove \(voice.displayName)", role: .destructive, action: onDelete)
            }
        }
        .listRowChrome(last: last, hovering: hovering)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: Lists

/// A card holding rows split by hairlines; rows draw their own via `listRowChrome`.
private struct ListCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        Card(padding: 0) {
            VStack(spacing: 0) { content }
                .clipShape(RoundedRectangle(cornerRadius: Brand.cardRadius, style: .continuous))
        }
    }
}

private extension View {
    /// Padding, a hover wash and the hairline under every row but the last.
    func listRowChrome(last: Bool, hovering: Bool = false) -> some View {
        self
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Brand.sunken.opacity(0.55) : Color.clear)
            .overlay(alignment: .bottom) {
                if !last { Rectangle().fill(Brand.line).frame(height: 1).padding(.leading, 16) }
            }
    }
}

// MARK: - Hotkeys

private struct HotkeysPanel: View {
    @Environment(\.settingsSkin) private var skin
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: SettingsStore

    @State private var recording: HotkeyAction?
    @State private var problems: [HotkeyAction: String] = [:]
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            yapperKeyCard

            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: "On the Yapper key")
                HotkeyList {
                    row(.readLatest, subtitle: "Tap. Pauses and resumes while playing; double-tap reads the focused chat.")
                    row(.talk, subtitle: settings.customShortcuts[.talk] == nil
                        ? "Hold and speak. Let go, or press Return, to type it where you are. You send it."
                        : "Hold and speak, let go to type. Or tap a shortcut to start and again to finish.")
                    row(.keepListening, subtitle: settings.customShortcuts[.keepListening] == nil
                        ? "While talking, press Space and let go. Press the key again to finish."
                        : "While talking, press Space or a shortcut. A shortcut alone starts listening; press it again to finish.",
                        last: true)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: "Chords")
                HotkeyList {
                    row(.readSelection, subtitle: "Speak the selected text.")
                    row(.repasteLast, subtitle: settings.yapperKey == .rightCommand
                        ? "Right ⌘ + V is the system's paste, so add a shortcut for this one."
                        : "Type what you last said again, when a paste missed.")
                    row(.toggleConversation, subtitle: "Read new assistant replies as they arrive.")
                    row(.skipNext, subtitle: "Next queued reply. Idle, the chord stays the app's.")
                    row(.dumpAXTree, subtitle: "Save the focused app's accessibility tree, for debugging.", last: true)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: "Keys for the app")
                HotkeyList {
                    row(.pressReturn,
                        subtitle: "Presses Return in the app you're in, from any key or mouse button. Does nothing while a dictation is still typing.",
                        last: true)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(Brand.faint)
                Text("Use + to add your own shortcuts, as many per action as you like. Each needs ⌃, ⌥ or ⌘, or use an F-key or a mouse's extra button on its own.")
                    .settingsBody(11)
                    .foregroundStyle(Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
                Button("Replay setup guide") { state.pendingOnboardingOpen = true }
                    .controlSize(.small)
            }
            .padding(.horizontal, 2)
        }
        .onDisappear { stopRecording() }
    }

    private var yapperKeyCard: some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: "keyboard")
                    .settingsFont(size: 14, weight: .semibold)
                    .foregroundStyle(skin.iconTint)
                    .iconTile(skin.iconChipBG, size: 34)
                RowLabel("Yapper key",
                         subtitle: "One right-hand modifier runs everything below. The left-hand one is never touched.")
                Spacer(minLength: 16)
                Picker("", selection: $settings.yapperKey) {
                    ForEach(YapperKey.allCases) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            if let caveat = settings.yapperKey.caveat {
                RowDivider()
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Brand.faint)
                    Text(caveat)
                        .settingsBody(11)
                        .foregroundStyle(Brand.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Rows that take shortcuts

    private func row(_ action: HotkeyAction, subtitle: String, last: Bool = false) -> some View {
        let extras = settings.customShortcuts[action] ?? []
        let isRecording = recording == action
        // Press Return has no Yapper-key gesture, only what's recorded here.
        let hasChord = action != .pressReturn
        var chord: [KeyCap] = [.named(settings.yapperKey.keycap)]
        if let key = chordKey(action) { chord.append(key) }
        return HotkeyListRow(title: action.title,
                             subtitle: problems[action] ?? (isRecording ? "Press the shortcut you want, or a mouse button over this window. Esc cancels." : subtitle),
                             warning: problems[action] != nil,
                             last: last) {
            HStack(spacing: 8) {
                if hasChord {
                    ChordKeys(keys: chord, suffix: action == .talk ? "hold" : nil)
                } else if extras.isEmpty, !isRecording {
                    Text("Not set")
                        .settingsFont(size: 11.5, weight: .medium)
                        .foregroundStyle(Brand.faint)
                }
                ForEach(Array(extras.enumerated()), id: \.element) { index, shortcut in
                    if hasChord || index > 0 { OrLabel() }
                    ShortcutCap(label: shortcut.parts.joined()) { remove(shortcut, from: action) }
                }
                if isRecording {
                    if hasChord || !extras.isEmpty { OrLabel() }
                    ShortcutCap(label: "Type shortcut", remove: nil)
                }
                if isRecording {
                    RowIconButton(symbol: "xmark", help: "Cancel") { stopRecording() }
                } else {
                    RowIconButton(symbol: "plus", help: "Add a shortcut for \(action.title)") { startRecording(action) }
                        .accessibilityLabel("Add shortcut for \(action.title)")
                }
            }
        }
    }

    private func chordKey(_ action: HotkeyAction) -> KeyCap? {
        switch action {
        case .readLatest, .talk, .pressReturn: nil
        case .keepListening:      .named("Space")
        case .readSelection:      .letter("S")
        case .repasteLast:        .letter("V")
        case .toggleConversation: .symbol("return")
        case .skipNext:           .symbol("arrow.right")
        case .dumpAXTree:         .letter("D")
        }
    }

    private func remove(_ shortcut: KeyShortcut, from action: HotkeyAction) {
        settings.customShortcuts[action]?.removeAll { $0 == shortcut }
        if settings.customShortcuts[action]?.isEmpty == true { settings.customShortcuts[action] = nil }
    }

    // MARK: Recording a shortcut

    /// Listens in the Settings window only. The event tap stands aside while this runs, so the
    /// shortcut being recorded never fires Yapper's current bindings.
    private func startRecording(_ action: HotkeyAction) {
        stopRecording()
        problems[action] = nil
        recording = action
        state.hotkeys.isRecordingShortcut = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown]) { event in
            record(event, for: action)
            return nil
        }
    }

    private func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let recording { problems[recording] = nil }
        recording = nil
        state.hotkeys.isRecordingShortcut = false
    }

    private func record(_ event: NSEvent, for action: HotkeyAction) {
        let flags = UInt64(event.modifierFlags.intersection([.control, .option, .shift, .command]).rawValue)
        let shortcut: KeyShortcut
        if event.type == .otherMouseDown {
            shortcut = KeyShortcut(mouseButton: Int64(event.buttonNumber), modifiers: flags)
        } else {
            let keyCode = Int64(event.keyCode)
            if keyCode == KeyShortcut.Code.escape, flags == 0 {
                stopRecording()
                return
            }
            shortcut = KeyShortcut(keyCode: keyCode, modifiers: flags,
                                   keyLabel: KeyShortcut.label(keyCode: keyCode,
                                                               characters: event.characters(byApplyingModifiers: [])))
        }
        if let problem = shortcut.problem(adding: action, among: settings.customShortcuts,
                                          yapperKey: settings.yapperKey) {
            problems[action] = problem   // stay recording, so the next try just works
            return
        }
        settings.customShortcuts[action, default: []].append(shortcut)
        stopRecording()
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
                    .settingsFont(size: 12.5, weight: w, design: mono ? .monospaced : .default)
            case .symbol(let s):
                Image(systemName: s)
                    .settingsFont(size: 13, weight: .semibold)
            }
        }
        // Light keycaps, like the key chips on the site: white, a hairline, a 1pt base.
        .foregroundStyle(Brand.ink)
        .frame(minWidth: width ?? 0, minHeight: 28)
        .padding(.horizontal, width == nil ? 11 : 0)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Brand.surface)
                .shadow(color: Brand.ink.opacity(0.14), radius: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Brand.lineStrong, lineWidth: 1)
        )
    }
}

/// One card holding a list of hotkey rows, split by hairlines.
private struct HotkeyList<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        Card(padding: 0) { content }
    }
}

/// Title and subtitle on the left, the keys on the right.
private struct HotkeyListRow<Keys: View>: View {
    let title: String
    let subtitle: String
    var warning = false
    var last = false
    @ViewBuilder var keys: Keys
    @Environment(\.settingsSkin) private var skin

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .settingsBody(13, .semibold)
                    .foregroundStyle(Brand.ink)
                // Red is kept for REC and destructive; a clash just reads louder.
                Label {
                    Text(subtitle).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    if warning { Image(systemName: "exclamationmark.circle.fill") }
                }
                .labelStyle(SubtitleLabelStyle(showsIcon: warning))
                .settingsBody(11.5, warning ? .medium : .regular)
                .foregroundStyle(warning ? Brand.ink : Brand.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) { keys }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Brand.line).frame(height: 1).padding(.leading, 18) }
        }
    }
}

private struct SubtitleLabelStyle: LabelStyle {
    let showsIcon: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if showsIcon { configuration.icon }
            configuration.title
        }
    }
}

/// The Yapper-key chord: keycaps joined by a light plus, with an optional word after ("hold").
private struct ChordKeys: View {
    let keys: [KeyCap]
    var suffix: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { idx, key in
                if idx > 0 {
                    Image(systemName: "plus")
                        .settingsFont(size: 8, weight: .bold)
                        .foregroundStyle(Brand.faint)
                }
                key.view
            }
            if let suffix {
                Text(suffix)
                    .settingsFont(size: 11.5, weight: .medium)
                    .foregroundStyle(Brand.muted)
                    .padding(.leading, 2)
            }
        }
        .fixedSize()
    }
}

private struct OrLabel: View {
    var body: some View {
        Text("or")
            .settingsFont(size: 11, weight: .medium)
            .foregroundStyle(Brand.faint)
    }
}

/// A recorded shortcut as one keycap ("⌃⇧P"). Hover shows its remove button; right-click too.
/// With no `remove` it is the dashed slot waiting for a key press.
private struct ShortcutCap: View {
    let label: String
    let remove: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        Text(label)
            .settingsFont(size: 12.5, weight: remove == nil ? .medium : .semibold)
            .foregroundStyle(remove == nil ? Brand.muted : Brand.ink)
            .frame(minHeight: 28)
            .padding(.horizontal, 10)
            .background {
                if remove == nil {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Brand.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                } else {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Brand.surface)
                        .shadow(color: Brand.ink.opacity(0.14), radius: 0, y: 1)
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Brand.lineStrong, lineWidth: 1))
                }
            }
            .overlay(alignment: .topTrailing) {
                if let remove {
                    Button(action: remove) {
                        Image(systemName: "xmark")
                            .settingsFont(size: 7, weight: .heavy)
                            .foregroundStyle(.white)
                            .frame(width: 15, height: 15)
                            .background(Circle().fill(Brand.muted))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                    .opacity(hovering ? 1 : 0)
                    .help("Remove \(label)")
                    .accessibilityLabel("Remove \(label)")
                }
            }
            .onHover { hovering = $0 }
            .contextMenu {
                if let remove { Button("Remove \(label)", role: .destructive, action: remove) }
            }
            // The hover button is invisible to VoiceOver until hovered; this keeps removal reachable.
            .accessibilityAction(named: Text("Remove")) { remove?() }
    }
}

// MARK: - Providers

private struct ProvidersPanel: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.settingsSkin) private var skin

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Deliberately first. Yapper reads text the moment it is installed, with no account
            // and no card on file — everything below this card is an upgrade, not a requirement.
            // Burying that under an API key form is how a free app reads as a paid one.
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Built in — nothing to sign up for")
                Card {
                    HStack(alignment: .center, spacing: 16) {
                        Image(systemName: "apple.logo")
                            .settingsFont(size: 14, weight: .semibold)
                            .foregroundStyle(skin.iconTint)
                            .iconTile(skin.iconChipBG, size: 32)

                        RowLabel("macOS system voice",
                                 subtitle: "Free, offline, private. No key, no account, no usage limit. Choose the voice under Voices.")
                        Spacer()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "ElevenLabs — optional, paid")
                Card {
                    VStack(alignment: .leading, spacing: 16) {
                        APIKeyField(provider: .elevenLabs)

                        Rectangle().fill(Brand.line).frame(height: 1)

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Model")
                                .settingsBody(13, .semibold)
                            VStack(spacing: 8) {
                                ForEach(ElevenLabsModel.allCases) { model in
                                    ModelOption(
                                        title: model.displayName,
                                        subtitle: "\(model.characterLimit / 1000)k char limit per request",
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
                SectionLabel(text: "OpenAI — optional, paid")
                Card {
                    VStack(alignment: .leading, spacing: 16) {
                        APIKeyField(provider: .openAI)

                        Rectangle().fill(Brand.line).frame(height: 1)

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Model")
                                .settingsBody(13, .semibold)
                            VStack(spacing: 8) {
                                ForEach(OpenAIModel.allCases) { model in
                                    ModelOption(
                                        title: model.displayName,
                                        subtitle: model.blurb,
                                        isSelected: settings.openAIModelID == model.id,
                                        onSelect: { settings.openAIModelID = model.id }
                                    )
                                }
                            }
                        }

                        Text("OpenAI voices synthesize one sentence at a time with no cross-sentence stitching, so seams are slightly more audible than ElevenLabs.")
                            .settingsBody(11)
                            .foregroundStyle(Brand.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Offline fallback")
                Card {
                    HStack(alignment: .center, spacing: 16) {
                        Image(systemName: "wifi.slash")
                            .settingsFont(size: 14, weight: .semibold)
                            .foregroundStyle(skin.iconTint)
                            .iconTile(skin.iconChipBG, size: 32)

                        RowLabel("Use macOS native voice when offline",
                                 subtitle: "Falls back to Samantha when a paid provider is unreachable.")
                        Spacer()
                        Toggle("", isOn: $settings.useNativeVoiceOffline)
                            .labelsHidden()
                            .toggleStyle(.ink)
                            .tint(skin.controlTint)
                    }
                }
            }
        }
    }
}

private struct ModelOption: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let onSelect: () -> Void
    @Environment(\.settingsSkin) private var skin

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? skin.accent : Brand.ink.opacity(0.25),
                                      lineWidth: isSelected ? 5 : 1.5)
                        .frame(width: 16, height: 16)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .settingsBody(13, .semibold)
                        .foregroundStyle(Brand.ink)
                    Text(subtitle)
                        .settingsBody(11)
                        .foregroundStyle(Brand.muted)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? skin.selectionFill : Brand.ink.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? skin.accent.opacity(0.5) : Brand.ink.opacity(0.08),
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
    @State private var showUninstalled = false

    private var installed: [ConvWatchApp] { Self.catalog.filter(\.isInstalled) }
    private var uninstalled: [ConvWatchApp] { Self.catalog.filter { !$0.isInstalled } }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Card {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .settingsFont(size: 14, weight: .semibold)
                        .foregroundStyle(skin.iconTint)
                        .iconTile(skin.iconChipBG, size: 34)
                    RowLabel("On when Yapper starts",
                             subtitle: "Otherwise turn it on with \(settings.yapperKey.keycap) + Return whenever you want replies read.")
                    Spacer(minLength: 16)
                    // Conversation Mode is the REC latch — it reads red in tape mode.
                    Toggle("", isOn: $settings.conversationDefaultOn)
                        .labelsHidden()
                        .toggleStyle(.ink)
                        .tint(skin.controlTint)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: "Watched apps")
                ListCard {
                    ForEach(Array(installed.enumerated()), id: \.element.id) { idx, app in
                        WatchedAppRow(app: app, last: idx == installed.count - 1 && uninstalled.isEmpty)
                    }
                    if !uninstalled.isEmpty {
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { showUninstalled.toggle() }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "chevron.right")
                                    .settingsFont(size: 9, weight: .bold)
                                    .rotationEffect(.degrees(showUninstalled ? 90 : 0))
                                Text("Not installed: \(uninstalled.map(\.name).joined(separator: ", "))")
                                    .lineLimit(1)
                                Spacer()
                            }
                            .settingsBody(11.5)
                            .foregroundStyle(Brand.muted)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowChrome(last: !showUninstalled)
                        if showUninstalled {
                            ForEach(Array(uninstalled.enumerated()), id: \.element.id) { idx, app in
                                WatchedAppRow(app: app, last: idx == uninstalled.count - 1)
                            }
                        }
                    }
                }
                Text("Yapper reads each new reply from these as it finishes, even in the background. Browsers count only while their active tab is an AI site.")
                    .settingsBody(11.5)
                    .foregroundStyle(Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .padding(.horizontal, 2)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(Brand.faint)
                Text("\(settings.yapperKey.keycap) + → skips to the next reply. With hands-free on (Voice in → Talk) the mic opens after each reply so you can answer; Yapper never presses Return.")
                    .settingsBody(11.5)
                    .foregroundStyle(Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 2)
        }
    }

    struct ConvWatchApp: Identifiable {
        let id: String        // bundle identifier
        let name: String
        let strategy: String  // shown as the row subtitle when installed
        let isBrowser: Bool

        var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }
        var isInstalled: Bool { appURL != nil }
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
    let last: Bool

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
            Group {
                if let url = app.appURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .interpolation(.high)
                } else {
                    Image(systemName: app.isBrowser ? "globe" : "app")
                        .settingsFont(size: 14)
                        .foregroundStyle(Brand.faint)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .settingsBody(13, .medium)
                    .foregroundStyle(app.isInstalled ? Brand.ink : Brand.muted)
                Text(app.isInstalled ? app.strategy : "Not installed")
                    .settingsBody(11)
                    .foregroundStyle(Brand.muted)
            }
            Spacer()
            if app.isInstalled {
                Toggle("", isOn: binding)
                    .labelsHidden()
                    .toggleStyle(.ink)
                    .tint(skin.controlTint)
            }
        }
        .listRowChrome(last: last)
    }
}

// MARK: - Voice In

/// Local speech-to-text controls: master switch, mic permission, speech model, hands-free.
struct VoiceInSection: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var state: AppState
    @Environment(\.settingsSkin) private var skin
    @State private var inputDevices: [AudioInputDevice] = []
    @AppStorage(MouthWavLM.earKey) private var mouthEar = MouthWavLM.heads[0]
    @State private var mouthEars: [(name: String, lookahead: Int)] = []
    @ObservedObject private var formatter: SmartFormatter = AppState.shared.formatter
    @Environment(\.settingsNavigate) private var navigate

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 16) {
                    Image(systemName: "mic.fill")
                        .settingsFont(size: 14, weight: .semibold)
                        .foregroundStyle(Brand.blueDeep)
                        .iconTile(Brand.blueSoft, size: 34)
                    RowLabel("Voice in",
                             subtitle: "Hold \(settings.yapperKey.keycap) to talk. Transcribed on this Mac, typed into the focused app.")
                    Spacer()
                    Toggle("", isOn: $settings.voiceInputEnabled)
                        .labelsHidden()
                        .toggleStyle(.ink)
                        .tint(skin.controlTint)
                }
                .padding(.bottom, 4)

                RowDivider()
                microphoneRow
                RowDivider()
                modelRow
                RowDivider()
                handsFreeRow
                RowDivider()
                pauseMediaRow
                RowDivider()
                toggleRow(icon: "capsule", title: "Recording pill",
                          detail: "A small pill at the bottom of the screen shows your mic level while you talk, then a tick when the words land.",
                          isOn: $settings.dictationHUD)
                RowDivider()
                pillStyleRow
                if settings.pillStyle == .mouth && mouthEars.count > 1 {
                    RowDivider()
                    mouthEarRow
                }
                RowDivider()
                toggleRow(icon: "speaker.wave.2", title: "Sounds",
                          detail: "A soft chime when the mic opens for a hold and when the words land. Yapper takes the chime back out of the recording.",
                          isOn: $settings.dictationSounds)
                RowDivider()
                cleanUpRow
                if formatter.status != .unsupported {
                    RowDivider()
                    formattingRow
                }
                if inputDevices.count > 1 {
                    RowDivider()
                    inputDeviceRow
                }
            }
        }
        .onAppear {
            inputDevices = AudioInputDevices.list()
            mouthEars = MouthWavLM.installedHeads()
            state.voiceInput.refreshMicrophonePermission()
        }
    }

    // MARK: Rows

    private var microphoneRow: some View {
        HStack(spacing: 12) {
            Image(systemName: state.hasMicrophonePermission ? "checkmark.circle.fill" : "exclamationmark.circle")
                .settingsFont(size: 13, weight: .medium)
                .foregroundStyle(state.hasMicrophonePermission ? Brand.led : Color.orange)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Microphone").settingsBody(13, .semibold)
                Text(state.hasMicrophonePermission ? "Access granted" : "Yapper needs microphone access to listen")
                    .settingsBody(11)
                    .foregroundStyle(Brand.muted)
            }
            Spacer()
            if !state.hasMicrophonePermission {
                Button("Grant…") {
                    Task {
                        _ = await MicrophonePermission.request()
                        state.voiceInput.refreshMicrophonePermission()
                        if !state.hasMicrophonePermission { MicrophonePermission.openSystemSettings() }
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private var modelRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "cpu")
                    .settingsFont(size: 13, weight: .medium)
                    .foregroundStyle(skin.iconTint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Speech model: \(WhisperModel.named(settings.whisperModelID).displayName)")
                        .settingsBody(13, .semibold)
                    Text(modelStatusLine)
                        .settingsBody(11)
                        .foregroundStyle(Brand.muted)
                }
                Spacer()
                Button("Models…") { navigate(.models) }
                    .controlSize(.small)
            }
            if case .downloading(let progress) = state.whisperModelStatus {
                ProgressView(value: progress)
                    .tint(skin.controlTint)
                    .padding(.leading, 34)
            }
        }
    }

    private var modelStatusLine: String {
        switch state.whisperModelStatus {
        case .notDownloaded: return "Not downloaded yet. Pick one in Models."
        case .downloaded: return "On disk. Loads when Voice in is switched on."
        case .downloading(let p): return "Downloading… \(Int(p * 100))%"
        case .loading: return "Loading onto the Neural Engine…"
        case .ready: return "Ready."
        case .failed(let message): return "Failed: \(message)"
        }
    }

    private func toggleRow(icon: String, title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .settingsFont(size: 13, weight: .medium)
                .foregroundStyle(skin.iconTint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).settingsBody(13, .semibold)
                Text(detail).settingsBody(11).foregroundStyle(Brand.muted)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.ink)
                .tint(skin.controlTint)
                .disabled(!settings.voiceInputEnabled)
        }
    }

    private var pillStyleRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "mouth")
                .settingsFont(size: 13, weight: .medium)
                .foregroundStyle(skin.iconTint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("On the pill").settingsBody(13, .semibold)
                Text("A mouth that moves with your voice as you talk, or the level bars.")
                    .settingsBody(11)
                    .foregroundStyle(Brand.muted)
            }
            Spacer()
            Picker("", selection: $settings.pillStyle) {
                ForEach(PillStyle.allCases) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 130)
            .disabled(!settings.voiceInputEnabled || !settings.dictationHUD)
        }
    }

    /// Only shown when both WavLM ears are installed: which one reads the lips, and so how far behind
    /// your voice the mouth runs. Takes effect at the next recording.
    private var mouthEarRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "ear.and.waveform")
                .settingsFont(size: 13, weight: .medium)
                .foregroundStyle(skin.iconTint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Mouth timing").settingsBody(13, .semibold)
                Text("Hearing further ahead gets more sounds right, but the mouth runs that much behind your voice.")
                    .settingsBody(11)
                    .foregroundStyle(Brand.muted)
            }
            Spacer()
            Picker("", selection: $mouthEar) {
                ForEach(mouthEars, id: \.name) { ear in
                    Text("\(ear.name) · \(Int(MouthTimeline.playout(shapeLag: ear.lookahead) * 1000)) ms").tag(ear.name)
                }
            }
            .labelsHidden()
            .frame(width: 170)
            .disabled(!settings.voiceInputEnabled || !settings.dictationHUD)
        }
    }

    private var handsFreeRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "ear")
                .settingsFont(size: 13, weight: .medium)
                .foregroundStyle(skin.iconTint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Hands-free after each reply").settingsBody(13, .semibold)
                Text("When Conversation Mode finishes reading a response, the mic opens until you pause. Nothing is sent — you press Return.")
                    .settingsBody(11)
                    .foregroundStyle(Brand.muted)
            }
            Spacer()
            Toggle("", isOn: $settings.handsFreeEnabled)
                .labelsHidden()
                .toggleStyle(.ink)
                .tint(skin.controlTint)
                .disabled(!settings.voiceInputEnabled)
        }
    }

    private var pauseMediaRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "pause.circle")
                .settingsFont(size: 13, weight: .medium)
                .foregroundStyle(skin.iconTint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pause media while you or Yapper talk").settingsBody(13, .semibold)
                Text("A video or song in another app pauses while you hold the talk key or Yapper reads, and plays again once you're both done. In Conversation Mode it waits for the reply too.")
                    .settingsBody(11)
                    .foregroundStyle(Brand.muted)
            }
            Spacer()
            Toggle("", isOn: $settings.pauseMediaWhileTalking)
                .labelsHidden()
                .toggleStyle(.ink)
                .tint(skin.controlTint)
                .disabled(!settings.voiceInputEnabled)
        }
    }

    private var cleanUpRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "eraser")
                .settingsFont(size: 13, weight: .medium)
                .foregroundStyle(skin.iconTint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Clean up stumbles").settingsBody(13, .semibold)
                Text("Takes out um and uh, stutters, words said twice, and filler like \"you know\" that's never meant. Instant, on every dictation.")
                    .settingsBody(11)
                    .foregroundStyle(Brand.muted)
            }
            Spacer()
            Toggle("", isOn: $settings.cleanUpSpeech)
                .labelsHidden()
                .toggleStyle(.ink)
                .tint(skin.controlTint)
                .disabled(!settings.voiceInputEnabled)
        }
    }

    private var formattingRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "list.number")
                .settingsFont(size: 13, weight: .medium)
                .foregroundStyle(skin.iconTint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Smart formatting").settingsBody(13, .semibold)
                Text(formattingDetail)
                    .settingsBody(11)
                    .foregroundStyle(Brand.muted)
            }
            Spacer()
            switch formatter.status {
            case .notDownloaded, .failed:
                Button("Download \(FormatterModel.approxSize)") {
                    formatter.download()
                    settings.smartFormattingEnabled = true
                }
                .controlSize(.small)
                .disabled(!settings.voiceInputEnabled)
            case .downloading(let progress):
                ProgressView(value: progress).frame(width: 90)
            case .verifying:
                ProgressView().controlSize(.small)
            case .ready, .unsupported:
                Toggle("", isOn: $settings.smartFormattingEnabled)
                    .labelsHidden()
                    .toggleStyle(.ink)
                    .tint(skin.controlTint)
                    .disabled(!settings.voiceInputEnabled)
            }
        }
        .contextMenu {
            if formatter.status == .ready {
                Button("Delete the formatting model (\(FormatterModel.approxSize))") {
                    settings.smartFormattingEnabled = false
                    Task { await formatter.deleteModel() }
                }
            }
        }
    }

    private var formattingDetail: String {
        let what = "Say \"first… second…\" and it types a list; say \"3, no wait, 4\" and it types 4. Runs \(FormatterModel.displayName) on this Mac, only when a dictation needs it. If the result changes your words, your words go out as spoken."
        switch formatter.status {
        case .failed(let why): return why
        case .downloading(let p): return "Downloading \(FormatterModel.displayName)… \(Int(p * 100))%"
        case .verifying: return "Checking the download…"
        default: return what
        }
    }

    private var inputDeviceRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.circle")
                .settingsFont(size: 13, weight: .medium)
                .foregroundStyle(skin.iconTint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Input").settingsBody(13, .semibold)
                Text("Which microphone to listen with.")
                    .settingsBody(11)
                    .foregroundStyle(Brand.muted)
            }
            Spacer()
            Picker("", selection: $settings.inputDeviceUID) {
                Text("System default").tag(String?.none)
                ForEach(inputDevices) { device in
                    Text(device.name).tag(Optional(device.uid))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 230)
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
        VStack(alignment: .leading, spacing: 28) {
            Card {
                HStack(spacing: 14) {
                    RowLabel("Keep spoken items for",
                             subtitle: "Older ones are deleted for good. Nothing here leaves this Mac.")
                    Spacer(minLength: 16)
                    RetentionPicker(hours: $settings.historyRetentionHours)
                }
                RowDivider()
                HStack(spacing: 14) {
                    RowLabel("Clear history", subtitle: "Delete everything Yapper has read aloud.")
                    Spacer(minLength: 16)
                    Button("Clear…", role: .destructive) { confirmingClear = true }
                        .disabled(state.history.entries.isEmpty)
                        .confirmationDialog("Clear all history?", isPresented: $confirmingClear) {
                            Button("Clear history", role: .destructive) { state.history.clearAll() }
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: "Recent")
                Spacer()
                if !history.entries.isEmpty {
                    Text("\(history.entries.count) item\(history.entries.count == 1 ? "" : "s")")
                        .settingsBody(11)
                        .foregroundStyle(Brand.faint)
                        .padding(.bottom, 10)
                }
            }
            ListCard {
                if history.entries.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(history.entries.enumerated()), id: \.element.id) { idx, entry in
                        HistoryRow(entry: entry,
                                   last: idx == history.entries.count - 1,
                                   onReplay: { onReplay(entry) },
                                   onDelete: { onDelete(entry) })
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("Nothing read yet")
                .settingsBody(13, .semibold)
                .foregroundStyle(Brand.muted)
            Text("What Yapper reads aloud shows up here, to play again.")
                .settingsBody(11.5)
                .foregroundStyle(Brand.faint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let last: Bool
    let onReplay: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false
    @Environment(\.settingsSkin) private var skin

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.preview)
                    .settingsBody(12.5)
                    .lineLimit(2)
                    .foregroundStyle(Brand.ink)
                HStack(spacing: 5) {
                    Image(systemName: entry.origin.symbol)
                        .settingsFont(size: 9, weight: .semibold)
                    Text("\(entry.sourceApp) · \(relativeTime(entry.createdAt))")
                }
                .settingsBody(11)
                .foregroundStyle(Brand.faint)
            }
            Spacer(minLength: 8)
            RowIconButton(symbol: "trash", help: "Remove", role: .destructive, action: onDelete)
                .opacity(hovering ? 1 : 0)
            RowIconButton(symbol: "play.fill", help: "Play again", action: onReplay)
        }
        .listRowChrome(last: last, hovering: hovering)
        .onHover { hovering = $0 }
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

/// The retention window as a menu of sensible stops; an odd value from an older build is kept
/// as its own entry rather than shown blank.
private struct RetentionPicker: View {
    @Binding var hours: Int

    private static let stops = [1, 6, 12, 24, 72, 168]

    private var options: [Int] {
        Self.stops.contains(hours) ? Self.stops : (Self.stops + [hours]).sorted()
    }

    var body: some View {
        Picker("", selection: $hours) {
            ForEach(options, id: \.self) { Text(Self.label($0)).tag($0) }
        }
        .labelsHidden()
        .frame(width: 130)
    }

    static func label(_ h: Int) -> String {
        if h % 24 == 0 {
            let d = h / 24
            return d == 7 ? "1 week" : "\(d) day\(d == 1 ? "" : "s")"
        }
        return "\(h) hour\(h == 1 ? "" : "s")"
    }
}

// MARK: - About

/// Marketing version from the bundle so release bumps (scripts/release.sh) propagate
/// everywhere the version is shown without touching this file.
let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
/// The macOS version the app is currently running on, e.g. "macOS 14".
let platformVersion = "macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"

/// Neutral panel fill for the first-run guide's standard skin. `.background.secondary` is a
/// hierarchical ShapeStyle level that needs macOS 14; on Ventura fall back to the window background.
var neutralPanelFill: AnyShapeStyle {
    if #available(macOS 14, *) {
        return AnyShapeStyle(.background.secondary)
    } else {
        return AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
    }
}

private struct AboutPanel: View {
    var body: some View {
        VStack(spacing: 18) {
            YapperGlyph(size: 76)
                .padding(.top, 36)

            VStack(spacing: 8) {
                Text("Yapper")
                    .settingsDisplay(44)
                    .tracking(-0.5)
                Text("Reads your AI out loud. ") + Text("Types what you say.").italic()
            }
            .settingsDisplay(19)
            .foregroundStyle(Brand.ink)

            HStack(spacing: 8) {
                InfoPill(label: "VERSION", value: appVersion)
                InfoPill(label: "PLATFORM", value: platformVersion)
            }
            .padding(.top, 6)

            VStack(spacing: 4) {
                Text("Free and open source. Speech is transcribed on this Mac.")
                Text("Mouth shapes learned from LibriTTS (Zen et al.), CC BY 4.0.")
                    .settingsFont(size: 10.5)
            }
            .settingsFont(size: 12)
            .foregroundStyle(Brand.muted)
            .multilineTextAlignment(.center)
            .padding(.top, 4)
            .padding(.bottom, 34)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [Brand.sunken, Brand.surface],
                                     startPoint: .top, endPoint: .center))
                .shadow(color: Brand.ink.opacity(0.05), radius: 1, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Brand.line, lineWidth: 1)
        )
    }
}

private struct InfoPill: View {
    let label: String
    let value: String
    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .settingsLabel(9.5)
                .tracking(1.2)
                .foregroundStyle(Brand.muted)
            Text(value)
                .settingsFont(size: 11.5, weight: .semibold, design: .monospaced)
                .foregroundStyle(Brand.ink)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule(style: .continuous).fill(Brand.surface))
        .overlay(Capsule(style: .continuous).strokeBorder(Brand.line, lineWidth: 1))
    }
}

// MARK: - Buttons

/// The site's primary button: an ink capsule with white type, so the blue stays rare.
struct PrimaryButton: View {
    let title: String
    let systemImage: String?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

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
                        .settingsFont(size: 11, weight: .bold)
                }
                Text(title)
                    .settingsFont(size: 12.5, weight: .semibold)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(hovering && isEnabled ? Brand.inkHover : Brand.ink)
                    .shadow(color: Brand.ink.opacity(0.22), radius: 1, y: 1)
            )
            .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5).padding(0.5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A round ink play button, for replaying a voice or a reading.
struct PlayDisc: View {
    let action: () -> Void
    var help = "Play"
    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .settingsFont(size: 10, weight: .bold)
                .foregroundStyle(.white)
                .offset(x: 1)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Brand.ink))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
