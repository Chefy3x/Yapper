import SwiftUI
import AppKit

// MARK: - Brand (standard skin)

/// The Settings look, taken from the website (site/index.html :root): a warm paper ground,
/// white cards, ink type, New York for headlines, and electric blue as the one bright accent.
enum Brand {
    static let canvas    = Color(hex: 0xF7F6F2)   // window ground
    static let rail      = Color(hex: 0xF1EFE9)   // sidebar, a step darker than the ground
    static let surface   = Color.white            // cards
    static let sunken    = Color(hex: 0xF4F3EE)   // wells inside a card: search, chips, icon tiles
    static let ink       = Color(hex: 0x141412)
    static let muted     = Color(hex: 0x77746B)
    static let faint     = Color(hex: 0xA6A299)
    static let line      = Color(hex: 0x141412).opacity(0.08)
    static let lineStrong = Color(hex: 0x141412).opacity(0.14)

    static let inkHover  = Color(hex: 0x2A2A27)   // primary buttons are ink, hover lifts a step
    static let blue      = Color(hex: 0x315CF5)   // sparing: the logo tile, small marks (white on it)
    static let blueSoft  = Color(hex: 0xE5EBFE)   // selected rows, chips
    static let blueDeep  = Color(hex: 0x2447C9)   // accent text and icons on white
    static let blueOnDark = Color(hex: 0x7D97FF)  // accent type on the dark LCD chip
    static let red       = Color(hex: 0xC74537)   // REC and destructive only
    static let led       = Color(hex: 0x3E9E5B)   // "all good"
    static let lcd       = Color(hex: 0x1B1A17)   // the dark counter chip behind eyebrow numbers

    static let railWidth: CGFloat = 228
    static let contentMaxWidth: CGFloat = 660
    static let sectionSpacing: CGFloat = 44
    static let cardRadius: CGFloat = 14

    /// Headlines: New York, the serif that ships with macOS, standing in for the site's Instrument Serif.
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .regular, design: .serif) }
    /// Small uppercase labels, like the site's tape-counter eyebrows.
    static func label(_ size: CGFloat = 10.5) -> Font { .system(size: size, weight: .semibold, design: .monospaced) }

    /// Stable, deterministic accent colors for voice avatars (standard skin).
    static let avatarPalette: [Color] = [
        Color(hex: 0x8FA6F7), Color(hex: 0xE9C46A), Color(hex: 0xF0A58F),
        Color(hex: 0x9CC5E8), Color(hex: 0xC7B3E6), Color(hex: 0xA9D8C1),
    ]
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

extension View {
    /// The small rounded tile an icon sits on at the start of a row.
    func iconTile(_ fill: Color, size: CGFloat = 32) -> some View {
        frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(fill))
    }
}

/// Everyday buttons on the light Settings: a white capsule with a hairline, ink type.
/// Set once on the window, so every Button that doesn't pick a style gets it.
struct SoftButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .settingsFont(size: 12, weight: .medium)
            .foregroundStyle(configuration.role == .destructive ? Brand.red : Brand.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(configuration.isPressed ? Brand.sunken : Brand.surface)
                    .shadow(color: Brand.ink.opacity(0.06), radius: 0.5, y: 0.5)
            )
            .overlay(Capsule(style: .continuous).strokeBorder(Brand.lineStrong, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

/// The light Settings switch: ink when on, a sunken track when off. Drawn rather than native
/// so it reads the same whether or not the window is key.
struct InkSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label
            Capsule(style: .continuous)
                .fill(configuration.isOn ? Brand.ink : Brand.ink.opacity(0.13))
                .frame(width: 34, height: 20)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                        .padding(2)
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isOn)
                .opacity(isEnabled ? 1 : 0.4)
                .onTapGesture { if isEnabled { configuration.isOn.toggle() } }
                .accessibilityElement()
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(configuration.isOn ? "On" : "Off")
                .accessibilityAction { if isEnabled { configuration.isOn.toggle() } }
        }
    }
}

extension ToggleStyle where Self == InkSwitchStyle {
    static var ink: InkSwitchStyle { InkSwitchStyle() }
}

// MARK: - Tape (cassette skin)

/// The tape-label identity, sampled from the deck artwork. Accent/text values
/// track site/styleguide.html; the window *ground* below is deliberately pulled
/// to a neutral near-black (Claude-dark) with NO warm cast, so the Settings
/// chrome reads black — not brown or khaki. Warm cream survives only in text and
/// the deck art; the surfaces stay neutral. (Site swatches still show the warm ground.)
enum Tape {
    static let void      = Color(red: 0.063, green: 0.063, blue: 0.063)  // #101010 neutral near-black ground
    static let panel     = Color(red: 0.106, green: 0.106, blue: 0.106)  // #1B1B1B neutral raised surface
    static let panelHi   = Color(red: 0.129, green: 0.129, blue: 0.129)  // #212121 neutral gradient top
    static let cream     = Color(red: 0.925, green: 0.890, blue: 0.796)  // #ECE3CB primary text
    static let yellow    = Color(red: 0.867, green: 0.788, blue: 0.545)  // #DDC98B THE accent
    static let yellowHi  = Color(red: 0.918, green: 0.875, blue: 0.682)  // #EADFAE paper gradient
    static let yellowLo  = Color(red: 0.788, green: 0.690, blue: 0.416)  // #C9B06A paper gradient
    static let ink       = Color(red: 0.094, green: 0.071, blue: 0.024)  // #181206 text on paper
    static let recRed    = Color(red: 0.647, green: 0.227, blue: 0.180)  // #A53A2E live / destructive
    static let recRedHot = Color(red: 0.780, green: 0.271, blue: 0.216)  // #C74537 LED / stamp
    static let acid      = Color(red: 0.659, green: 0.776, blue: 0.212)  // #A8C636 "playing" — one per view

    static var dust: Color  { cream.opacity(0.60) }   // secondary text
    static var faint: Color { cream.opacity(0.34) }   // tertiary text
    static var line: Color  { cream.opacity(0.14) }   // hairlines on dark

    /// Deterministic avatar discs, tape edition — muted cream tones so a list of
    /// voices reads as neutral chips, not a row of yellow dots.
    static let avatarPalette: [Color] = [
        cream.opacity(0.78), cream.opacity(0.60), cream.opacity(0.86),
        cream.opacity(0.68), cream.opacity(0.54), cream.opacity(0.72)
    ]

    /// Paper card fill (158° on the web ≈ topLeading → bottomTrailing here).
    static var paperGradient: LinearGradient {
        LinearGradient(colors: [yellowHi, yellow, yellowLo],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    /// Dark panel fill.
    static var panelGradient: LinearGradient {
        LinearGradient(colors: [panelHi, panel], startPoint: .top, endPoint: .bottom)
    }

    // MARK: Type voices

    /// SHOUT — SF Compressed Black is the native Impact. Pair with uppercased strings.
    static func shout(_ size: CGFloat) -> Font {
        .system(size: size, weight: .black).width(.compressed)
    }
    /// MARKER — Marker Felt ships with macOS; fall back to rounded if it ever vanishes.
    static func marker(_ size: CGFloat) -> Font {
        for name in ["MarkerFelt-Wide", "MarkerFelt-Thin", "Marker Felt"] where NSFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: .semibold, design: .rounded)
    }
    /// MONO — liner-note body and labels.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Skin

/// Which clothes the Settings window wears. Derived from the mini-player theme:
/// the tape identity switches on with the Cassette shell and off with Minimal.
enum SettingsSkin {
    case standard, tape

    var accent: Color      { self == .tape ? Tape.yellow : Brand.blueDeep }
    var accentDeep: Color  { self == .tape ? Tape.yellowLo : Brand.blueDeep }
    var accentSoft: Color  { self == .tape ? Tape.yellow.opacity(0.13) : Brand.blueSoft }
    /// Switches, sliders and progress: ink on the light skin, so the blue stays rare.
    var controlTint: Color { self == .tape ? Tape.recRed : Brand.ink }
    /// Conversation Mode controls — the REC latch is red in tape mode.
    var liveTint: Color    { self == .tape ? Tape.recRed : Brand.ink }
    var destructive: Color { self == .tape ? Tape.recRed : Brand.red }
    var okTint: Color      { self == .tape ? Tape.acid : Brand.led }

    /// Decorative section-icon glyphs and their tile — neutral, so the accent stays an accent.
    var iconTint: Color      { self == .tape ? Tape.cream.opacity(0.82) : Brand.ink.opacity(0.72) }
    var iconChipBG: Color    { self == .tape ? Color.white.opacity(0.05) : Brand.sunken }
    /// Selection highlight fill — the accent lives in the border, so a selection reads without flooding the row.
    var selectionFill: Color { self == .tape ? Color.white.opacity(0.05) : Brand.blueSoft.opacity(0.55) }

    /// Display voice for panel titles and big numbers.
    func display(_ size: CGFloat, standardWeight: Font.Weight = .bold) -> Font {
        self == .tape ? Tape.shout(size) : Brand.display(size)
    }
    /// Body/label voice.
    func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        self == .tape ? Tape.mono(size, weight) : .system(size: size, weight: weight)
    }

    func avatarColor(for id: String) -> Color {
        var hash: UInt64 = 5381
        for byte in id.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        let palette = self == .tape ? Tape.avatarPalette : Brand.avatarPalette
        return palette[Int(hash % UInt64(palette.count))]
    }
}

private struct SettingsSkinKey: EnvironmentKey {
    static let defaultValue: SettingsSkin = .standard
}

extension EnvironmentValues {
    var settingsSkin: SettingsSkin {
        get { self[SettingsSkinKey.self] }
        set { self[SettingsSkinKey.self] = newValue }
    }
}

// MARK: - Scale

/// How much bigger Settings draws its type than at the base column width. The Settings window
/// sets it from its own width, so widening the window grows the cards and the words together;
/// everywhere else (the menu bar, the guide) it stays 1.
private struct SettingsScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var settingsScale: CGFloat {
        get { self[SettingsScaleKey.self] }
        set { self[SettingsScaleKey.self] = newValue }
    }
}

extension Brand {
    /// The most the type grows, so a full-screen window reads large rather than enormous.
    static let maxScale: CGFloat = 1.35

    /// The scale for a content area `width` wide: 1 up to the base column, then in step with it.
    static func scale(forContentWidth width: CGFloat) -> CGFloat {
        min(max(width / contentMaxWidth, 1), maxScale)
    }
}

/// Sets a Settings font at its base size, scaled by `settingsScale`. Sizes stay written as they
/// look at the base width; only these modifiers know about the window.
private struct SettingsFont: ViewModifier {
    enum Voice {
        case system(Font.Weight, Font.Design)
        case body(Font.Weight)
        case display
        case label
    }

    let size: CGFloat
    let voice: Voice
    @Environment(\.settingsScale) private var scale
    @Environment(\.settingsSkin) private var skin

    func body(content: Content) -> some View {
        let s = size * scale
        switch voice {
        case .system(let weight, let design): content.font(.system(size: s, weight: weight, design: design))
        case .body(let weight):               content.font(skin.body(s, weight))
        case .display:                        content.font(Brand.display(s))
        case .label:                          content.font(Brand.label(s))
        }
    }
}

extension View {
    /// `.font(.system(size:weight:design:))` that grows with the Settings window.
    func settingsFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(SettingsFont(size: size, voice: .system(weight, design)))
    }
    /// `.font(skin.body(…))` that grows with the Settings window.
    func settingsBody(_ size: CGFloat, _ weight: Font.Weight = .regular) -> some View {
        modifier(SettingsFont(size: size, voice: .body(weight)))
    }
    /// `.font(Brand.display(…))` that grows with the Settings window.
    func settingsDisplay(_ size: CGFloat) -> some View {
        modifier(SettingsFont(size: size, voice: .display))
    }
    /// `.font(Brand.label(…))` that grows with the Settings window.
    func settingsLabel(_ size: CGFloat = 10.5) -> some View {
        modifier(SettingsFont(size: size, voice: .label))
    }
}

// MARK: - Bits

/// 1pt dashed hairline — dark panels use dashed dividers in the tape skin.
struct DashedHairline: View {
    var color: Color = Tape.line
    var body: some View {
        DashShape()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            .foregroundStyle(color)
            .frame(height: 1)
    }
    private struct DashShape: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.width, y: rect.midY))
            return p
        }
    }
}

/// Compact keycap for dense surfaces — the menu bar reference strip and the first-run guide.
/// Deliberately flatter and smaller than the Settings keycaps: a 280pt menu wants a legible
/// label, not a row of 3D keys, and it has to sit quietly in both light and dark appearance.
struct MiniKeycap: View {
    enum Content {
        case text(String)
        case symbol(String)   // SF Symbol name
    }
    let content: Content
    var body: some View {
        Group {
            switch content {
            case .text(let s):
                Text(s).settingsFont(size: 10.5, weight: .semibold)
            case .symbol(let s):
                Image(systemName: s).settingsFont(size: 9, weight: .bold)
            }
        }
        .foregroundStyle(.primary.opacity(0.75))
        .padding(.horizontal, 5)
        .frame(minWidth: 18, minHeight: 18)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
    }
}

/// One line of the Yapper-key contract: the key cluster, then what it does.
/// Shared so the menu bar strip and the guide's recap can never drift apart.
struct ShortcutLine: View {
    let caps: [MiniKeycap.Content]
    let label: String
    /// Width of the key column — keeps every label in a list left-aligned with the others.
    var capColumnWidth: CGFloat = 104

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                    MiniKeycap(content: cap)
                }
            }
            .frame(width: capColumnWidth, alignment: .leading)

            Text(label)
                .settingsFont(size: 11)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The user-facing gestures, in the order they matter. The AX dump (key + D) is a
/// debug affordance and deliberately absent — it lives in Settings only.
///
/// One key does both directions (hold to talk, tap to read), so every gesture says which side it
/// belongs to, and every list of them is drawn in those groups.
enum ShortcutReference {
    enum Group: String, CaseIterable {
        case voiceIn = "Voice in"
        case readAloud = "Read aloud"
        /// Both at once: Yapper reads, then listens for your answer.
        case conversation = "Conversation"
    }

    struct Item {
        let group: Group
        let caps: [MiniKeycap.Content]
        let label: String
    }

    static func all(yapperKey key: YapperKey) -> [Item] {
        let cap = MiniKeycap.Content.text(key.keycap)
        return [
            Item(group: .voiceIn, caps: [cap, .text("hold")], label: "Talk — release to type"),
            Item(group: .voiceIn, caps: [cap, .text("hold"), .text("Space")], label: "Lock the mic — press again to type"),
            Item(group: .voiceIn, caps: [cap, .text("V")], label: "Paste the last dictation again"),
            Item(group: .readAloud, caps: [cap], label: "Read latest / pause"),
            Item(group: .readAloud, caps: [cap, .text("S")], label: "Read selected text"),
            Item(group: .readAloud, caps: [cap, .symbol("arrow.right")], label: "Skip ahead"),
            Item(group: .conversation, caps: [cap, .symbol("return")], label: "Conversation Mode"),
        ]
    }

    static func items(in group: Group, yapperKey key: YapperKey) -> [Item] {
        all(yapperKey: key).filter { $0.group == group }
    }
}

/// The small capitals over a group of shortcuts or menu items.
struct ShortcutGroupHeading: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .settingsFont(size: 9, weight: .semibold)
            .tracking(0.8)
            .foregroundStyle(.tertiary)
            .padding(.bottom, 1)
    }
}

/// The J-card barcode, drawn from a fixed stripe pattern.
struct TapeBarcode: View {
    var height: CGFloat = 22
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array([2, 2, 1, 3, 2, 1, 1, 4, 2, 1, 3, 1, 2, 2, 1, 1, 3, 2, 1, 2, 4, 1, 2, 1].enumerated()),
                    id: \.offset) { i, w in
                Rectangle()
                    .fill(i.isMultiple(of: 2) ? Tape.cream.opacity(0.75) : .clear)
                    .frame(width: CGFloat(w) * 1.5)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
