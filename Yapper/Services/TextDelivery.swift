import AppKit
import CoreGraphics

/// What the coordinator needs to get text on screen. The real one pastes; tests capture.
protocol TextDelivering: Sendable {
    /// Puts `text` into the focused field of the frontmost app. Never presses Return.
    func deliver(_ text: String) async throws
}

/// Types a transcript into whatever has keyboard focus by pasting it. Paste is the one route
/// that works everywhere — native text views, Electron composers, browser contenteditables —
/// where AX value-setting is hit-or-miss. The pasteboard is snapshotted and restored in full,
/// same as the read path: clipboard stays sacred.
struct PasteDelivery: TextDelivering {
    enum DeliveryError: LocalizedError {
        case noFrontmostApp, eventSourceUnavailable
        var errorDescription: String? {
            switch self {
            case .noFrontmostApp: "No app is focused to type into"
            case .eventSourceUnavailable: "Couldn't post the paste keystroke"
            }
        }
    }

    /// How long the target app gets to read the pasteboard before we put the old contents back.
    /// Electron apps read on the next runloop turn; a generous window costs nothing visible.
    static let settleTime: TimeInterval = 0.35

    func deliver(_ text: String) async throws {
        try await Self.paste(text)
    }

    @AXWorker
    private static func paste(_ text: String) throws {
        guard NSWorkspace.shared.frontmostApplication != nil else { throw DeliveryError.noFrontmostApp }
        let pb = NSPasteboard.general
        let prior = AccessibilityReader.pasteboardSnapshot(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)

        guard let src = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: 9 /* V */, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        else {
            AccessibilityReader.restorePasteboard(pb, from: prior)
            throw DeliveryError.eventSourceUnavailable
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        Thread.sleep(forTimeInterval: settleTime)
        AccessibilityReader.restorePasteboard(pb, from: prior)
    }
}
