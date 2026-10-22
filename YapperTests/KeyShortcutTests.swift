import Testing
import CoreGraphics
import Foundation

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

    @Test func talkTakesShortcutsLikeTheRest() {
        let f13 = KeyShortcut(keyCode: 105, modifiers: 0, keyLabel: "F13")
        #expect(f13.problem(adding: .talk, among: [:], yapperKey: .rightOption) == nil)
        let shortcuts: [HotkeyAction: [KeyShortcut]] = [.talk: [f13, ctrlShiftR]]
        #expect(KeyShortcut.action(for: 105, flags: [], in: shortcuts) == .talk)
        #expect(ctrlShiftR.problem(adding: .readSelection, among: shortcuts, yapperKey: .rightOption) == "Already used by Talk.")
    }

    @Test func keepListeningTakesShortcutsButNotItsOwnSpaceChord() {
        let f14 = KeyShortcut(keyCode: 107, modifiers: 0, keyLabel: "F14")
        #expect(f14.problem(adding: .keepListening, among: [:], yapperKey: .rightOption) == nil)
        #expect(KeyShortcut.action(for: 107, flags: [], in: [.keepListening: [f14]]) == .keepListening)
        let optSpace = KeyShortcut(keyCode: KeyShortcut.Code.space, modifiers: KeyShortcut.option, keyLabel: "Space")
        #expect(optSpace.problem(adding: .keepListening, among: [:], yapperKey: .rightOption) != nil)
    }

    @Test func anExtraMouseButtonIsAShortcutOnItsOwn() {
        let back = KeyShortcut(mouseButton: 3, modifiers: 0)
        #expect(back.keyLabel == "Mouse 4")
        #expect(back.problem(adding: .talk, among: [:], yapperKey: .rightOption) == nil)
        let shortcuts: [HotkeyAction: [KeyShortcut]] = [.talk: [back]]
        #expect(KeyShortcut.action(forMouseButton: 3, flags: [], in: shortcuts) == .talk)
        #expect(KeyShortcut.action(forMouseButton: 3, flags: .maskCommand, in: shortcuts) == nil)
        #expect(KeyShortcut.action(forMouseButton: 4, flags: [], in: shortcuts) == nil)
        // A mouse button never matches the key with the same number, nor the other way round.
        #expect(KeyShortcut.action(for: 3, flags: [], in: shortcuts) == nil)
        let f = KeyShortcut(keyCode: 3, modifiers: KeyShortcut.control, keyLabel: "F")
        #expect(KeyShortcut.action(forMouseButton: 3, flags: .maskControl, in: [.talk: [f]]) == nil)
    }

    @Test func leftAndRightClicksAreRefused() {
        #expect(KeyShortcut(mouseButton: 0, modifiers: KeyShortcut.command).problem(adding: .talk, among: [:], yapperKey: .rightOption) != nil)
        #expect(KeyShortcut(mouseButton: 1, modifiers: 0).problem(adding: .talk, among: [:], yapperKey: .rightOption) != nil)
    }

    @Test func shortcutsSavedBeforeMouseButtonsStillDecode() throws {
        let old = #"{"keyCode":15,"modifiers":262144,"keyLabel":"R"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(KeyShortcut.self, from: old)
        #expect(decoded.mouseButton == nil)
        #expect(decoded.matches(keyCode: 15, flags: .maskControl))
    }

    @Test func aQuickTalkPressLocksAndAHoldDoesNot() {
        #expect(TalkShortcut.locksOnRelease(heldFor: 0.15))
        #expect(!TalkShortcut.locksOnRelease(heldFor: ModifierGesture.holdThreshold))
        #expect(!TalkShortcut.locksOnRelease(heldFor: 3))
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
