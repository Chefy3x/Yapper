import CoreGraphics
import Foundation

/// What a recorded shortcut can trigger. Each keeps its Yapper-key gesture or chord; shortcuts
/// are extra ways in. A Talk shortcut works both ways: hold it to talk and let go to type, or
/// press it once to start and again to finish (see `TalkShortcut`). A Keep listening shortcut
/// does what Space does mid-talk, and on its own starts a dictation that the next press finishes.
enum HotkeyAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case readLatest, talk, keepListening, readSelection, repasteLast, toggleConversation, skipNext, dumpAXTree

    var id: String { rawValue }

    var title: String {
        switch self {
        case .readLatest:         "Read latest"
        case .talk:               "Talk"
        case .keepListening:      "Keep listening"
        case .readSelection:      "Read selection"
        case .repasteLast:        "Paste last transcript"
        case .toggleConversation: "Toggle Conversation Mode"
        case .skipNext:           "Skip ahead"
        case .dumpAXTree:         "AX debug dump"
        }
    }

    /// The keys that make this action's chord with the Yapper key. Read latest is a tap and
    /// Talk a hold: none. Keep listening's Space is only Yapper's mid-hold, and refused as a
    /// shortcut on its own (see `problem(adding:among:yapperKey:)`).
    var chordKeyCodes: Set<Int64> {
        switch self {
        case .readLatest:         []
        case .talk:               []
        case .keepListening:      []
        case .readSelection:      [KeyShortcut.Code.s]
        case .repasteLast:        [KeyShortcut.Code.v]
        case .toggleConversation: [KeyShortcut.Code.returnKey, KeyShortcut.Code.keypadEnter]
        case .skipNext:           [KeyShortcut.Code.rightArrow]
        case .dumpAXTree:         [KeyShortcut.Code.d]
        }
    }
}

/// A full shortcut (a key plus ⌃ ⌥ ⇧ ⌘) recorded in Settings → Hotkeys. An action can have
/// any number, on top of its Yapper-key chord. It can be a mouse's extra button instead of a
/// key: then `mouseButton` is set and `keyCode` means nothing.
struct KeyShortcut: Codable, Hashable, Sendable {
    /// Carbon virtual key code.
    var keyCode: Int64
    /// CGEventFlags bits, ⌃ ⌥ ⇧ ⌘ only. NSEvent.ModifierFlags uses the same bits.
    var modifiers: UInt64
    /// What the key prints, captured when it was recorded ("R", "↩", "F5").
    var keyLabel: String
    /// The mouse button's number, counted from 0 as macOS does (2 is the middle, 3 and up the
    /// extras). Nil for a key; shortcuts saved before mouse buttons decode as keys.
    var mouseButton: Int64?

    enum Code {
        static let s: Int64 = 1
        static let d: Int64 = 2
        static let v: Int64 = 9
        static let returnKey: Int64 = 36
        static let space: Int64 = 49
        static let escape: Int64 = 53
        static let keypadEnter: Int64 = 76
        static let rightArrow: Int64 = 124
    }

    static let control = CGEventFlags.maskControl.rawValue
    static let option = CGEventFlags.maskAlternate.rawValue
    static let shift = CGEventFlags.maskShift.rawValue
    static let command = CGEventFlags.maskCommand.rawValue
    static let modifierMask = control | option | shift | command

    init(keyCode: Int64, modifiers: UInt64, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.modifierMask
        self.keyLabel = keyLabel
    }

    /// A mouse button, with whatever modifiers were held when it was pressed.
    init(mouseButton: Int64, modifiers: UInt64) {
        self.init(keyCode: -1, modifiers: modifiers, keyLabel: Self.label(mouseButton: mouseButton))
        self.mouseButton = mouseButton
    }

    var isMouse: Bool { mouseButton != nil }

    /// Exact match on the four modifiers; fn and keypad bits (set by arrows, F-keys) are ignored.
    func matches(keyCode: Int64, flags: CGEventFlags) -> Bool {
        !isMouse && keyCode == self.keyCode && flags.rawValue & Self.modifierMask == modifiers
    }

    func matches(mouseButton: Int64, flags: CGEventFlags) -> Bool {
        mouseButton == self.mouseButton && flags.rawValue & Self.modifierMask == modifiers
    }

    /// F-keys and the mouse's extra buttons may stand alone; any other key needs ⌃, ⌥ or ⌘ or
    /// it would eat normal typing. Left and right clicks are never shortcuts.
    var isUsable: Bool {
        if let mouseButton { return mouseButton >= 2 }
        return modifiers & (Self.control | Self.option | Self.command) != 0 || Self.functionKeys[keyCode] != nil
    }

    /// "Middle click" for the wheel, then "Mouse 4", "Mouse 5"…, the way mouse makers number them.
    static func label(mouseButton: Int64) -> String {
        mouseButton == 2 ? "Middle click" : "Mouse \(mouseButton + 1)"
    }

    /// Keycaps in the order macOS menus print them: ⌃ ⌥ ⇧ ⌘, then the key.
    var parts: [String] {
        var out: [String] = []
        if modifiers & Self.control != 0 { out.append("⌃") }
        if modifiers & Self.option != 0 { out.append("⌥") }
        if modifiers & Self.shift != 0 { out.append("⇧") }
        if modifiers & Self.command != 0 { out.append("⌘") }
        out.append(keyLabel)
        return out
    }

    /// The label for a key: a symbol for keys that print nothing useful, else its character.
    static func label(keyCode: Int64, characters: String?) -> String {
        if let name = functionKeys[keyCode] ?? specialKeys[keyCode] { return name }
        let chars = (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return chars.isEmpty ? "Key \(keyCode)" : chars.uppercased()
    }

    private static let specialKeys: [Int64: String] = [
        36: "↩", 76: "⌤", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]

    private static let functionKeys: [Int64: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    /// Why `self` can't be added to `action`, or nil when it can. Clashes are checked against
    /// every recorded shortcut and against the Yapper-key chords, which are always live.
    func problem(adding action: HotkeyAction,
                 among shortcuts: [HotkeyAction: [KeyShortcut]],
                 yapperKey: YapperKey) -> String? {
        guard isUsable else {
            return isMouse ? "Left and right clicks can't be shortcuts." : "Add ⌃, ⌥ or ⌘ so it doesn't swallow normal typing."
        }
        if let owner = shortcuts.first(where: { $0.value.contains(self) })?.key {
            return owner == action ? "\(action.title) already has that one." : "Already used by \(owner.title)."
        }
        // The Yapper key's modifier alone + a chord key is a chord already.
        // fn has no CGEventFlags twin here, so it can't collide.
        guard !isMouse, let chordFlag = yapperKey.chordFlag, modifiers == chordFlag else { return nil }
        if keyCode == Code.space { return "That's \(yapperKey.keycap) + Space, which locks the mic." }
        if let owner = HotkeyAction.allCases.first(where: { $0.chordKeyCodes.contains(keyCode) }) {
            return "That's already the \(yapperKey.keycap) chord for \(owner.title)."
        }
        return nil
    }

    /// The action a key press triggers, if it matches any recorded shortcut.
    static func action(for keyCode: Int64, flags: CGEventFlags,
                       in shortcuts: [HotkeyAction: [KeyShortcut]]) -> HotkeyAction? {
        shortcuts.first { $0.value.contains { $0.matches(keyCode: keyCode, flags: flags) } }?.key
    }

    /// The action a mouse button triggers, if it matches any recorded shortcut.
    static func action(forMouseButton button: Int64, flags: CGEventFlags,
                       in shortcuts: [HotkeyAction: [KeyShortcut]]) -> HotkeyAction? {
        shortcuts.first { $0.value.contains { $0.matches(mouseButton: button, flags: flags) } }?.key
    }
}

/// A recorded Talk shortcut opens the mic on press; how long it was held decides the rest.
/// Held like the Yapper key, it's push-to-talk: letting go types it. Pressed and let go
/// quickly, the mic stays open until the next press, the way Space locks a Yapper-key hold.
enum TalkShortcut {
    /// Same line as the Yapper key's tap-versus-hold.
    static func locksOnRelease(heldFor: TimeInterval) -> Bool {
        heldFor < ModifierGesture.holdThreshold
    }
}

extension YapperKey {
    /// The device-independent modifier the Yapper key sets. Nil for fn.
    var chordFlag: UInt64? {
        switch self {
        case .rightOption:  KeyShortcut.option
        case .rightControl: KeyShortcut.control
        case .rightCommand: KeyShortcut.command
        case .fn:           nil
        }
    }
}
