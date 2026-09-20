import Testing
import Foundation

/// The Yapper-key tap-versus-hold reducer, driven with explicit timestamps.
struct ModifierGestureTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    @Test func quickPressAndReleaseIsATap() {
        var g = ModifierGesture()
        #expect(g.handle(.commandDown, at: at(0)) == .none)
        #expect(g.handle(.commandUp, at: at(0.2)) == .tap)
        #expect(!g.isDown)
    }

    @Test func holdBeginsAfterThresholdAndEndsOnRelease() {
        var g = ModifierGesture()
        _ = g.handle(.commandDown, at: at(0))
        #expect(g.handle(.holdTimerFired, at: at(ModifierGesture.holdThreshold)) == .holdBegan)
        #expect(g.holding)
        #expect(g.handle(.commandUp, at: at(3)) == .holdEnded)
        #expect(!g.holding && !g.isDown)
    }

    @Test func keyDuringHoldCancelsAndSuppressesTap() {
        var g = ModifierGesture()
        _ = g.handle(.commandDown, at: at(0))
        _ = g.handle(.holdTimerFired, at: at(0.5))
        #expect(g.handle(.otherKeyDown, at: at(0.6)) == .holdCancelled)
        #expect(g.handle(.commandUp, at: at(0.7)) == .none)
    }

    @Test func clickDuringHoldCancels() {
        var g = ModifierGesture()
        _ = g.handle(.commandDown, at: at(0))
        _ = g.handle(.holdTimerFired, at: at(0.5))
        #expect(g.handle(.mouseDown, at: at(0.6)) == .holdCancelled)
    }

    @Test func comboBeforeHoldFiresNeitherTapNorHold() {
        var g = ModifierGesture()
        _ = g.handle(.commandDown, at: at(0))
        #expect(g.handle(.otherKeyDown, at: at(0.1)) == .none)   // ⌘S etc.
        #expect(g.handle(.holdTimerFired, at: at(0.5)) == .none)  // timer still fires; must be inert
        #expect(g.handle(.commandUp, at: at(0.6)) == .none)
    }

    @Test func slowReleaseWithoutHoldTimerIsNothing() {
        var g = ModifierGesture()
        _ = g.handle(.commandDown, at: at(0))
        // Released between the tap window and the hold threshold — the dead zone.
        #expect(g.handle(.commandUp, at: at(0.42)) == .none)
    }

    @Test func staleHoldTimerAfterReleaseIsIgnored() {
        var g = ModifierGesture()
        _ = g.handle(.commandDown, at: at(0))
        _ = g.handle(.commandUp, at: at(0.1))
        #expect(g.handle(.holdTimerFired, at: at(0.5)) == .none)
    }

    @Test func eventsWithoutCommandDownAreIgnored() {
        var g = ModifierGesture()
        #expect(g.handle(.otherKeyDown, at: at(0)) == .none)
        #expect(g.handle(.commandUp, at: at(0)) == .none)
        #expect(g.handle(.holdTimerFired, at: at(0)) == .none)
    }
}
