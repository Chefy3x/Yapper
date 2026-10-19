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
        #expect(plain.problem(binding: .readSelection, among: [:], yapperKey: .rightOption) != nil)
        #expect(shifted.problem(binding: .readSelection, among: [:], yapperKey: .rightOption) != nil)
    }

    @Test func aBareFunctionKeyIsFine() {
        let f5 = KeyShortcut(keyCode: 96, modifiers: 0, keyLabel: "F5")
        #expect(f5.problem(binding: .readSelection, among: [:], yapperKey: .rightOption) == nil)
    }

    @Test func refusesAShortcutAnotherActionHas() {
        let taken: [HotkeyAction: KeyShortcut] = [.skipNext: ctrlShiftR]
        #expect(ctrlShiftR.problem(binding: .readSelection, among: taken, yapperKey: .rightOption) == "Already used by Skip ahead.")
        // Re-recording the same shortcut on its own action is fine.
        #expect(ctrlShiftR.problem(binding: .skipNext, among: taken, yapperKey: .rightOption) == nil)
    }

    @Test func refusesALiveYapperKeyChord() {
        let optS = KeyShortcut(keyCode: KeyShortcut.Code.s, modifiers: KeyShortcut.option, keyLabel: "S")
        #expect(optS.problem(binding: .repasteLast, among: [:], yapperKey: .rightOption) != nil)
        // Once Read selection has its own shortcut, ⌥S is free.
        #expect(optS.problem(binding: .repasteLast, among: [.readSelection: ctrlShiftR], yapperKey: .rightOption) == nil)
        // A different Yapper key means ⌥S never was a chord.
        #expect(optS.problem(binding: .repasteLast, among: [:], yapperKey: .rightControl) == nil)
    }

    @Test func refusesTheMicLockChord() {
        let optSpace = KeyShortcut(keyCode: KeyShortcut.Code.space, modifiers: KeyShortcut.option, keyLabel: "Space")
        #expect(optSpace.problem(binding: .readSelection, among: [:], yapperKey: .rightOption) != nil)
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
