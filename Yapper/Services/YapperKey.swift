import CoreGraphics

/// The one modifier that is Yapper's whole control surface: tap to read or pause, hold to talk,
/// chord with S / Return / → / D for the rest. Right ⌘ was the original and turned out to be a
/// poor fit: holding ⌘ makes many apps change state (link previews, alternate cursors, drag
/// modes), so a hold felt like the app under it misbehaving. Right ⌥ is inert on its own.
enum YapperKey: String, CaseIterable, Codable, Identifiable, Sendable {
    case rightOption, fn, rightControl, rightCommand

    var id: String { rawValue }

    static let `default`: YapperKey = .rightOption

    /// Carbon virtual key code carried by the flagsChanged event.
    var keyCode: Int64 {
        switch self {
        case .rightOption: 61
        case .fn: 63
        case .rightControl: 62
        case .rightCommand: 54
        }
    }

    /// True when the flags say this specific key is physically down. Uses the device-side
    /// masks (NX_DEVICER*KEYMASK) so a left modifier held for a chord doesn't masquerade.
    func isDown(_ flags: CGEventFlags) -> Bool {
        switch self {
        case .rightOption: flags.rawValue & 0x0040 != 0
        case .rightControl: flags.rawValue & 0x2000 != 0
        case .rightCommand: flags.rawValue & 0x0010 != 0
        case .fn: flags.contains(.maskSecondaryFn)
        }
    }

    var displayName: String {
        switch self {
        case .rightOption: "Right Option"
        case .fn: "Fn / Globe"
        case .rightControl: "Right Control"
        case .rightCommand: "Right Command"
        }
    }

    /// Short form for keycaps.
    var keycap: String {
        switch self {
        case .rightOption: "Right ⌥"
        case .fn: "fn"
        case .rightControl: "Right ⌃"
        case .rightCommand: "Right ⌘"
        }
    }

    /// Anything the user must know before picking this key. Chords are intercepted only on the
    /// right-hand key; the left one is never touched.
    var caveat: String? {
        switch self {
        case .rightOption:
            "Right ⌥ + → is taken only while Yapper is playing or has replies queued; otherwise it still jumps a word. Right ⌥ + S and + D stop typing ß and ∂."
        case .fn:
            "Set System Settings → Keyboard → “Press 🌐 key to” → Do Nothing, or macOS opens the emoji picker when you let go."
        case .rightControl:
            "Right ⌃ + S and + D are taken — in a terminal that's freeze-output and end-of-file. Use the left ⌃ for those."
        case .rightCommand:
            "Holding ⌘ changes state in many apps (link previews, alternate cursors). Right ⌘ + S / D / Return / → are taken from the app."
        }
    }
}
