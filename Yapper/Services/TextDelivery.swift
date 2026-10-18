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
///
/// The transcript goes on the pasteboard as a promise, not as data, so Yapper learns whether the
/// focused app actually read it. A fixed restore timer alone guesses: in a slow app it puts the
/// old clipboard back before the paste lands and the user gets yesterday's clipboard instead of
/// what they said, and when nothing is focused the words are simply gone.
struct PasteDelivery: TextDelivering {
    enum DeliveryError: LocalizedError {
        case noFrontmostApp, eventSourceUnavailable, notPasted
        var errorDescription: String? {
            switch self {
            case .noFrontmostApp: "No app is focused to type into"
            case .eventSourceUnavailable: "Couldn't post the paste keystroke"
            case .notPasted: "Nothing took the paste. It's on your clipboard: press ⌘V"
            }
        }
    }

    /// After the app reads the text, it gets this long to finish before the old contents return.
    static let afterReadGrace: TimeInterval = 0.1
    /// No read by then means the paste didn't land (no text field focused, secure input on).
    static let readTimeout: TimeInterval = 1.5
    /// The old contents never come back sooner than this. A promise doesn't say who read it, and
    /// a clipboard manager polling at the wrong moment looks exactly like the target app, so a
    /// read only ever extends the wait past the window that has always worked, never shortens it.
    /// The same window covers a read that came before the paste: the pasteboard caches the
    /// data then, and the target's own read is never seen.
    static let minimumSettle: TimeInterval = 0.35

    func deliver(_ text: String) async throws {
        let vKey = await MainActor.run { KeyboardLayout.keyCode() }   // TIS is main-thread only
        try await Self.paste(text, vKey: vKey)
    }

    @AXWorker
    private static func paste(_ text: String, vKey: CGKeyCode) throws {
        guard NSWorkspace.shared.frontmostApplication != nil else { throw DeliveryError.noFrontmostApp }
        let pb = NSPasteboard.general
        let prior = AccessibilityReader.pasteboardSnapshot(pb)
        let promise = PastePromise(text: text)
        let item = NSPasteboardItem()
        item.setDataProvider(promise, forTypes: [.string])
        pb.clearContents()
        pb.writeObjects([item])
        // Serving the promise doesn't move this; anything else writing the clipboard does.
        let ourChangeCount = pb.changeCount

        // A private event source carries only the flags set on the event. With the combined
        // session state, a key the user is still holding (Shift, the Yapper key itself) would
        // ride along and turn ⌘V into another shortcut.
        guard let src = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        else {
            AccessibilityReader.restorePasteboard(pb, from: prior)
            throw DeliveryError.eventSourceUnavailable
        }
        // Keep physical keystrokes out of the brief window around the synthetic ones.
        src.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents],
                                                       state: .eventSuppressionStateSuppressionInterval)
        let readsBeforePaste = promise.reads.count
        let postedAt = Date()
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        // The promise is served on the main thread, which stays free while this worker waits.
        while Date().timeIntervalSince(postedAt) < readTimeout {
            if promise.reads.contains(where: { $0 >= postedAt }) || readsBeforePaste > 0 { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let readAfterPaste = promise.reads.contains { $0 >= postedAt }
        if readAfterPaste || readsBeforePaste > 0 {
            let elapsed = Date().timeIntervalSince(postedAt)
            Thread.sleep(forTimeInterval: max(afterReadGrace, minimumSettle - elapsed))
            restoreIfUnchanged(pb, prior: prior, ourChangeCount: ourChangeCount)
            Log.voice.info("Paste read \(readAfterPaste ? "by the focused app" : "from cache", privacy: .public) after \(Int(Date().timeIntervalSince(postedAt) * 1000), privacy: .public)ms")
            return
        }
        // Nobody read it. Leave the words where the user can still get them, as plain data,
        // since the promise dies with this call. Unless something else has claimed the
        // clipboard meanwhile: that copy is the user's and wins.
        if pb.changeCount == ourChangeCount {
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
        Log.voice.notice("Paste not read within \(Int(readTimeout * 1000), privacy: .public)ms; transcript left on the clipboard")
        throw DeliveryError.notPasted
    }

    /// Puts the user's clipboard back — but only if nothing has written it since the paste. A
    /// copy made in that window is newer than the snapshot, and restoring would destroy it.
    @AXWorker
    private static func restoreIfUnchanged(_ pb: NSPasteboard, prior: [[NSPasteboard.PasteboardType: Data]],
                                           ourChangeCount: Int) {
        guard pb.changeCount == ourChangeCount else {
            Log.voice.notice("Clipboard changed since the paste; leaving it alone")
            return
        }
        AccessibilityReader.restorePasteboard(pb, from: prior)
    }
}

/// Supplies the transcript when an app asks for it and records when each ask happened.
private final class PastePromise: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let text: String
    private let lock = NSLock()
    private var readTimes: [Date] = []

    init(text: String) { self.text = text }

    var reads: [Date] {
        lock.lock(); defer { lock.unlock() }
        return readTimes
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        lock.lock(); readTimes.append(Date()); lock.unlock()
        item.setString(text, forType: type)
    }
}
