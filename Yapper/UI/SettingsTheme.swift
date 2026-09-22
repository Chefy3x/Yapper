import SwiftUI
import AppKit

// MARK: - Brand (standard skin)

/// Accent + layout constants for the standard Settings appearance.
/// (Moved out of SettingsView so both skins live in one file.)
enum Brand {
    static let blue = Color(red: 105/255, green: 144/255, blue: 191/255)
    static let blueDeep = Color(red: 72/255, green: 105/255, blue: 148/255)
    static let blueSoft = Color(red: 105/255, green: 144/255, blue: 191/255).opacity(0.12)

    static let railWidth: CGFloat = 220
    static let contentMaxWidth: CGFloat = 620
    static let sectionSpacing: CGFloat = 44

    /// Stable, deterministic accent colors for voice avatars (standard skin).
    static let avatarPalette: [Color] = [
        Color(red: 105/255, green: 144/255, blue: 191/255), // blue
        Color(red: 167/255, green: 116/255, blue: 202/255), // violet
        Color(red: 226/255, green: 132/255, blue: 116/255), // coral
        Color(red: 105/255, green: 178/255, blue: 152/255), // sage
        Color(red: 226/255, green: 174/255, blue: 92/255),  // amber
        Color(red: 113/255, green: 165/255, blue: 211/255), // sky
    ]
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

    var accent: Color      { self == .tape ? Tape.yellow : Brand.blue }
    var accentDeep: Color  { self == .tape ? Tape.yellowLo : Brand.blueDeep }
    var accentSoft: Color  { self == .tape ? Tape.yellow.opacity(0.13) : Brand.blueSoft }
    /// Conversation Mode controls — the REC latch is red in tape mode.
    var liveTint: Color    { self == .tape ? Tape.recRed : Brand.blue }
    var destructive: Color { self == .tape ? Tape.recRed : .red }
    var okTint: Color      { self == .tape ? Tape.acid : .green }

    /// Decorative section-icon glyphs and their chip — neutral in tape so yellow
    /// stays an accent, not a surface. Standard keeps its blue chips unchanged.
    var iconTint: Color      { self == .tape ? Tape.cream.opacity(0.82) : Brand.blue }
    var iconChipBG: Color    { self == .tape ? Color.white.opacity(0.05) : Brand.blueSoft }
    /// Selection highlight fill — a faint neutral wash in tape; the accent lives
    /// in the border, so yellow signals a selection without flooding the row.
    var selectionFill: Color { self == .tape ? Color.white.opacity(0.05) : Brand.blueSoft }

    /// Display voice for panel titles and big numbers.
    func display(_ size: CGFloat, standardWeight: Font.Weight = .bold) -> Font {
        self == .tape ? Tape.shout(size) : .system(size: size, weight: standardWeight)
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
                Text(s).font(.system(size: 10.5, weight: .semibold))
            case .symbol(let s):
                Image(systemName: s).font(.system(size: 9, weight: .bold))
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
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The user-facing gestures, in the order they matter. The AX dump (key + D) is a
/// debug affordance and deliberately absent — it lives in Settings only.
enum ShortcutReference {
    static func all(yapperKey key: YapperKey) -> [(caps: [MiniKeycap.Content], label: String)] {
        let cap = MiniKeycap.Content.text(key.keycap)
        return [
            ([cap], "Read latest / pause"),
            ([cap, .text("hold")], "Talk — release to type"),
            ([cap, .text("S")], "Read selected text"),
            ([cap, .symbol("return")], "Conversation Mode"),
            ([cap, .symbol("arrow.right")], "Skip ahead"),
        ]
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
