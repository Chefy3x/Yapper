import AppKit
import CoreGraphics

/// What a paste landed in, so the field can be watched for the user's edits afterwards.
struct DeliveryReceipt: Sendable {
    /// What was actually typed: the transcript, fitted to the text around the cursor.
    var text: String = ""
    /// Nil when the app doesn't expose its focused element through Accessibility.
    var field: FocusedField?
    /// The field's text right after the paste, the baseline edits are measured against.
    var valueAfter: String?
    /// When the focused app took the text: the moment it appeared, for the lag log.
    var readAt: Date?
}

/// Where the user was when they started talking: the app, and the field if it could be read.
struct DeliveryTarget: Sendable {
    let pid: pid_t
    let appName: String?
    let field: FocusedField?

    /// The frontmost app and its focused field, right now.
    @AXWorker
    static func current() -> DeliveryTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        let field = FocusedField.current()
        return DeliveryTarget(pid: app.processIdentifier, appName: app.localizedName,
                              field: field?.pid == app.processIdentifier ? field : nil)
    }
}

/// What the coordinator needs to get text on screen. The real one pastes; tests capture.
protocol TextDelivering: Sendable {
    /// Puts `text` into the field the user was in when they started talking (`target`), or the
    /// focused field of the frontmost app. Never presses Return. `landed` runs the moment the
    /// app takes the text, before the clipboard is put back, so what should feel instant can be.
    @discardableResult
    func deliver(_ text: String, target: DeliveryTarget?,
                 landed: @escaping @Sendable () -> Void) async throws -> DeliveryReceipt
}

extension TextDelivering {
    @discardableResult
    func deliver(_ text: String, target: DeliveryTarget?) async throws -> DeliveryReceipt {
        try await deliver(text, target: target, landed: {})
    }
    @discardableResult
    func deliver(_ text: String) async throws -> DeliveryReceipt { try await deliver(text, target: nil) }
}

/// Types a transcript into whatever has keyboard focus by pasting it. Paste is the one route
/// that works everywhere — native text views, Electron composers, browser contenteditables —
/// where AX value-setting is hit-or-miss. The pasteboard is snapshotted and restored in full,
/// same as the read path: clipboard stays sacred.
///
/// The transcript goes on the pasteboard as a promise, not as data, so Yapper learns whether the
/// focused app actually read it. A fixed restore timer alone guesses: in a slow app it puts the
/// old clipboard back before the paste lands and the user gets yesterday's clipboard instead of
/// what they said. When nothing takes the paste at all, the clipboard is still put back (an image
/// or a video copied earlier must survive a missed dictation); the words wait for Paste last
/// transcript instead.
struct PasteDelivery: TextDelivering {
    enum DeliveryError: LocalizedError {
        case noFrontmostApp, eventSourceUnavailable, notPasted
        var errorDescription: String? {
            switch self {
            case .noFrontmostApp: "No app is focused to type into"
            case .eventSourceUnavailable: "Couldn't post the paste keystroke"
            case .notPasted: "Nothing took the paste"
            }
        }
    }

    /// After the app reads the text, it gets this long to finish before the old contents return.
    static let afterReadGrace: TimeInterval = 0.1
    /// No read this long after the retry means the paste didn't land (no text field focused,
    /// secure input on).
    static let readTimeout: TimeInterval = 1.5
    /// The old contents never come back sooner than this. A promise doesn't say who read it, and
    /// a clipboard manager polling at the wrong moment looks exactly like the target app, so a
    /// read only ever extends the wait past the window that has always worked, never shortens it.
    /// The same window covers a read that came before the paste: the pasteboard caches the
    /// data then, and the target's own read is never seen.
    static let minimumSettle: TimeInterval = 0.35
    /// No read by then and the field looks unchanged: the ⌘V is sent once more. Long enough that
    /// a slow app reading late is rare; the field check guards the rest against a double paste.
    static let retryAfter: TimeInterval = 0.75

    @discardableResult
    func deliver(_ text: String, target: DeliveryTarget?,
                 landed: @escaping @Sendable () -> Void) async throws -> DeliveryReceipt {
        let vKey = await MainActor.run { KeyboardLayout.keyCode() }   // TIS is main-thread only
        if let target { await Self.bringBack(target) }
        // Fit the words to what's around the cursor: mid-sentence they continue it.
        let context = await Self.cursorContext()
        let fitted = await MainActor.run {
            InsertionFit.fit(text, before: context?.before, after: context?.after) { WordKnowledge.isDictionaryWord($0) }
        }
        var receipt = try await Self.paste(fitted, vKey: vKey, landed: landed)
        receipt.text = fitted
        return receipt
    }

    /// Wispr Flow and Superwhisper both paste where you started talking, not where you are when
    /// the text is ready: switching apps while a long dictation transcribes shouldn't send it
    /// somewhere else. Only when that app is still running; otherwise the text goes to the
    /// current one.
    static let bringBackTimeout: TimeInterval = 1.0

    @AXWorker
    private static func bringBack(_ target: DeliveryTarget) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != target.pid,
              let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated else { return }
        app.activate()
        let started = Date()
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != target.pid,
              Date().timeIntervalSince(started) < bringBackTimeout {
            Thread.sleep(forTimeInterval: 0.02)
        }
        target.field?.refocus()
        Thread.sleep(forTimeInterval: 0.05)   // let the window take key focus before ⌘V
        Log.voice.info("Pasting back into \(target.appName ?? "the app you started in", privacy: .public)")
    }

    @AXWorker
    private static func cursorContext() -> (before: String, after: String)? {
        FocusedField.current()?.cursorContext()
    }

    @AXWorker
    private static func paste(_ text: String, vKey: CGKeyCode,
                              landed onLanded: @Sendable () -> Void) throws -> DeliveryReceipt {
        guard NSWorkspace.shared.frontmostApplication != nil else { throw DeliveryError.noFrontmostApp }
        let field = FocusedField.current()
        let valueBefore = field?.value
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
        func waitForRead(until deadline: TimeInterval) {
            while Date().timeIntervalSince(postedAt) < deadline {
                if promise.reads.contains(where: { $0 >= postedAt }) || readsBeforePaste > 0 { return }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        waitForRead(until: retryAfter)
        var landed = promise.reads.contains { $0 >= postedAt } || readsBeforePaste > 0
        var how = promise.reads.contains { $0 >= postedAt } ? "read by the focused app" : "read from cache"
        if !landed, let field, let before = valueBefore, let now = field.value, now != before {
            // Some apps take the text without asking for it again (a cached read we never saw).
            landed = true
            how = "seen in the field"
        }
        if !landed, field?.isTextInput ?? true {
            // A ⌘V that arrived while focus was still settling, or while a modifier was down,
            // goes nowhere. Wispr Flow and Superwhisper both send it once more; so does Yapper.
            Log.voice.notice("Paste not read after \(Int(retryAfter * 1000), privacy: .public)ms; sending ⌘V again")
            if let down2 = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
               let up2 = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false) {
                down2.flags = .maskCommand
                up2.flags = .maskCommand
                down2.post(tap: .cghidEventTap)
                up2.post(tap: .cghidEventTap)
            }
            waitForRead(until: retryAfter + readTimeout)
            landed = promise.reads.contains { $0 >= postedAt }
            how = "read after a retry"
        }
        if landed {
            onLanded()
            let elapsed = Date().timeIntervalSince(postedAt)
            Thread.sleep(forTimeInterval: max(afterReadGrace, minimumSettle - elapsed))
            restoreIfUnchanged(pb, prior: prior, ourChangeCount: ourChangeCount)
            Log.voice.info("Paste \(how, privacy: .public) after \(Int(Date().timeIntervalSince(postedAt) * 1000), privacy: .public)ms")
            let readAt = promise.reads.first { $0 >= postedAt } ?? (readsBeforePaste > 0 ? postedAt : nil)
            return DeliveryReceipt(field: field, valueAfter: field?.value, readAt: readAt)
        }
        // Nobody read it. The clipboard is the user's: put back what was there (an image, a
        // video, anything) rather than leave the words on it. Paste last transcript recovers them.
        restoreIfUnchanged(pb, prior: prior, ourChangeCount: ourChangeCount)
        Log.voice.notice("Paste not read; clipboard put back")
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
