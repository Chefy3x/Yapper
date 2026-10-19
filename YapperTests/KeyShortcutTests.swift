import Testing
import CoreGraphics

/// Recorded shortcuts: matching in the event tap, and what Settings refuses to bind.
struct KeyShortcutTests {
    private let ctrlShiftR = KeyShortcut(keyCode: 15, modifiers: KeyShortcut.control | KeyShortcut.shift, keyLabel: "R")

    @Test func matchesOnlyTheExactModifiers() {
        let both = CGEventFlags(rawValue: KeyShortcut.control | KeyShortcut.shift)
        #expect(ctrlShiftR.matches(keyCode: 15, flags: both))
        #expect(!ctrlShiftR.matches(keyCode: 15, flags: .maskControl))
        #expect(!ctrlShiftR.matches(keyCode: 15, flags: both.union(.maskCommand)))
        #expect(!ctrlShiftR.matches(keyCode: 14, flags: both))
    }

    @Test func ignoresFnAndKeypadBits() {
        let arrow = KeyShortcut(keyCode: 124, modifiers: KeyShortcut.control, keyLabel: "→")
        #expect(arrow.matches(keyCode: 124, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad]))
    }

    @Test func dropsNonModifierBitsWhenStored() {
        let s = KeyShortcut(keyCode: 15, modifiers: KeyShortcut.control | CGEventFlags.maskSecondaryFn.rawValue, keyLabel: "R")
        #expect(s.modifiers == KeyShortcut.control)
    }

    @Test func plainOrShiftOnlyKeysAreRefused() {
        let plain = KeyShortcut(keyCode: 15, modifiers: 0, keyLabel: "R")
        let shifted = KeyShortcut(keyCode: 15, modifiers: KeyShortcut.shift, keyLabel: "R")
        #expect(plain.problem(adding: .readSelection, among: [:], yapperKey: .rightOption) != nil)
        #expect(shifted.problem(adding: .readSelection, among: [:], yapperKey: .rightOption) != nil)
    }

    @Test func aBareFunctionKeyIsFine() {
        let f5 = KeyShortcut(keyCode: 96, modifiers: 0, keyLabel: "F5")
        #expect(f5.problem(adding: .readSelection, among: [:], yapperKey: .rightOption) == nil)
    }

    @Test func refusesAShortcutAlreadyInUse() {
        let taken: [HotkeyAction: [KeyShortcut]] = [.skipNext: [ctrlShiftR]]
        #expect(ctrlShiftR.problem(adding: .readSelection, among: taken, yapperKey: .rightOption) == "Already used by Skip ahead.")
        #expect(ctrlShiftR.problem(adding: .skipNext, among: taken, yapperKey: .rightOption) == "Skip ahead already has that one.")
    }

    @Test func anActionCanHaveSeveral() {
        let f5 = KeyShortcut(keyCode: 96, modifiers: 0, keyLabel: "F5")
        let shortcuts: [HotkeyAction: [KeyShortcut]] = [.repasteLast: [ctrlShiftR]]
        #expect(f5.problem(adding: .repasteLast, among: shortcuts, yapperKey: .rightOption) == nil)
        let both: [HotkeyAction: [KeyShortcut]] = [.repasteLast: [ctrlShiftR, f5]]
        #expect(KeyShortcut.action(for: 96, flags: [], in: both) == .repasteLast)
        #expect(KeyShortcut.action(for: 15, flags: CGEventFlags(rawValue: KeyShortcut.control | KeyShortcut.shift), in: both) == .repasteLast)
        #expect(KeyShortcut.action(for: 15, flags: [], in: both) == nil)
    }

    @Test func refusesAYapperKeyChord() {
        let optS = KeyShortcut(keyCode: KeyShortcut.Code.s, modifiers: KeyShortcut.option, keyLabel: "S")
        // Chords stay live alongside shortcuts, so ⌥S is never free with Right ⌥…
        #expect(optS.problem(adding: .repasteLast, among: [:], yapperKey: .rightOption) != nil)
        #expect(optS.problem(adding: .readSelection, among: [:], yapperKey: .rightOption) != nil)
        // …but with another Yapper key it never was a chord.
        #expect(optS.problem(adding: .repasteLast, among: [:], yapperKey: .rightControl) == nil)
    }

    @Test func refusesTheMicLockChord() {
        let optSpace = KeyShortcut(keyCode: KeyShortcut.Code.space, modifiers: KeyShortcut.option, keyLabel: "Space")
        #expect(optSpace.problem(adding: .readSelection, among: [:], yapperKey: .rightOption) != nil)
    }

    @Test func partsFollowMenuOrder() {
        let all = KeyShortcut(keyCode: 15, modifiers: KeyShortcut.modifierMask, keyLabel: "R")
        #expect(all.parts == ["⌃", "⌥", "⇧", "⌘", "R"])
    }

    @Test func labelsSpecialKeysBySymbol() {
        #expect(KeyShortcut.label(keyCode: 36, characters: "\r") == "↩")
        #expect(KeyShortcut.label(keyCode: 96, characters: nil) == "F5")
        #expect(KeyShortcut.label(keyCode: 15, characters: "r") == "R")
    }
}
