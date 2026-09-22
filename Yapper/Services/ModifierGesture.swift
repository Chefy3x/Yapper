import Foundation

/// The Yapper key's tap-versus-hold state machine, pulled out of the event tap so it can be
/// unit-tested with synthetic events. Works for any modifier — see `YapperKey`.
///
/// Contract:
///   • press + release under `tapThreshold`, nothing else touched  → `.tap`
///   • held past `holdThreshold` with nothing else touched         → `.holdBegan` (Voice In)
///     … then release                                               → `.holdEnded`
///     … or any key / mouse button while holding                   → `.holdCancelled`
///   • any key / click while down (before the hold fires)          → consumed, no tap on release
struct ModifierGesture {
    enum Event { case commandDown, commandUp, otherKeyDown, mouseDown, holdTimerFired }
    enum Action: Equatable { case none, tap, holdBegan, holdEnded, holdCancelled }

    static let tapThreshold: TimeInterval = 0.4
    /// Just past the tap window so a slow tap can't turn into a mic flicker.
    static let holdThreshold: TimeInterval = 0.45

    private(set) var downAt: Date?
    private(set) var consumedByCombo = false
    private(set) var holding = false

    var isDown: Bool { downAt != nil }

    mutating func handle(_ event: Event, at now: Date = Date()) -> Action {
        switch event {
        case .commandDown:
            downAt = now
            consumedByCombo = false
            holding = false
            return .none

        case .holdTimerFired:
            guard let downAt, !consumedByCombo, !holding,
                  now.timeIntervalSince(downAt) >= Self.holdThreshold - 0.01 else { return .none }
            holding = true
            return .holdBegan

        case .otherKeyDown, .mouseDown:
            guard isDown else { return .none }
            let wasHolding = holding
            consumedByCombo = true
            holding = false
            return wasHolding ? .holdCancelled : .none

        case .commandUp:
            defer { downAt = nil; consumedByCombo = false; holding = false }
            if holding { return .holdEnded }
            guard let downAt, !consumedByCombo,
                  now.timeIntervalSince(downAt) < Self.tapThreshold else { return .none }
            return .tap
        }
    }
}
