import AppKit
import CoreGraphics

/// Watches the keyboard via CGEventTap for Yapper's gestures on the **Yapper key** — one modifier
/// (Right ⌥ by default, see `YapperKey`) that is the whole control surface:
///   1. Tap (press + release, no other key, < 400ms)        -> readLatestOrPauseToggle
///   2. Hold (> 450ms, nothing else touched)                -> pushToTalk began / ended
///   3. Key + Enter                                         -> toggleConversationMode
///   4. Key + S                                             -> readSelection
///   5. Key + →                                             -> skipNext (only while playing/queued)
///   6. Key + D                                             -> AX tree dump (debug)
/// Chords 3, 4 and 6 are swallowed so the focused app never sees them. Chord 5 is swallowed only
/// when a skip means something; otherwise it passes through, because ⌥→ is word-jump in every
/// text field and stealing it would be a daily paper cut. Anything else pressed while the key
/// is held passes through unmodified, so it still works as a normal modifier.
///
/// Requires Accessibility permission. Without it, install() succeeds-but-does-nothing because the
/// tap will be disabled by the system.
@MainActor
final class HotkeyManager {
    // Carbon virtual key codes
    private enum KeyCode {
        static let s: Int64 = 1
        static let d: Int64 = 2
        static let returnKey: Int64 = 36
        static let keypadEnter: Int64 = 76
        static let rightArrow: Int64 = 124
    }

    var onReadLatestOrToggle: (() -> Void)?
    /// Hold the Yapper key past the tap window: the mic opens. Release: transcribe. Any other key
    /// or a click during the hold: the user meant a chord, cancel silently.
    var onPushToTalkBegan: (() -> Void)?
    var onPushToTalkEnded: (() -> Void)?
    var onPushToTalkCancelled: (() -> Void)?
    var onReadSelection: (() -> Void)?
    var onToggleConversationMode: (() -> Void)?
    var onDumpAXTree: (() -> Void)?
    var onSkipNext: (() -> Void)?
    /// Answers "would a skip do anything right now?" — playing or queued. Decides whether
    /// Key + → is Yapper's or the app's.
    var skipIsMeaningful: () -> Bool = { false }

    /// Which modifier is the Yapper key. Set from Settings by AppState; takes effect immediately.
    var key: YapperKey = .default {
        didSet { gesture = ModifierGesture(); holdTimer?.cancel(); holdTimer = nil }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Tap-versus-hold state machine (pure, unit-tested) + the timer that fires its hold event.
    private var gesture = ModifierGesture()
    private var holdTimer: DispatchWorkItem?

    func install() {
        guard eventTap == nil else { return }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: HotkeyManager.tapCallback,
            userInfo: selfPtr
        ) else {
            Log.hotkey.error("CGEvent.tapCreate failed — Accessibility permission not granted yet; install() will be retried once it is.")
            return
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.runLoopSource = source
        Log.hotkey.info("HotkeyManager installed on \(self.key.displayName, privacy: .public) (tap / hold / +S / +Return / +→ / +D).")
    }

    func uninstall() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
        return manager.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The OS can disable the tap if it's slow or if input events back up. Re-enable it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        switch type {
        case .flagsChanged:
            if keyCode == key.keyCode {
                if key.isDown(flags) {
                    dispatch(gesture.handle(.commandDown))
                    scheduleHoldTimer()
                } else {
                    holdTimer?.cancel()
                    holdTimer = nil
                    dispatch(gesture.handle(.commandUp))
                }
            }
            return Unmanaged.passUnretained(event)

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // A click while the key is held (⌥-click, ⌥-drag, …) is aimed at the focused app —
            // releasing right after must NOT count as a tap, and an open mic closes without
            // transcribing.
            dispatch(gesture.handle(.mouseDown))
            return Unmanaged.passUnretained(event)

        case .keyDown:
            // If the Yapper key is held, watch for our chords. Otherwise pass through.
            guard gesture.isDown else {
                return Unmanaged.passUnretained(event)
            }
            // Any keyDown while the key is held cancels the pending "tap" interpretation
            // (and an in-progress hold-to-talk).
            dispatch(gesture.handle(.otherKeyDown))

            // Key + Enter -> Conversation Mode toggle (swallowed)
            if keyCode == KeyCode.returnKey || keyCode == KeyCode.keypadEnter {
                DispatchQueue.main.async { [weak self] in self?.onToggleConversationMode?() }
                return nil
            }
            // Key + S -> Read Selection (swallowed)
            if keyCode == KeyCode.s {
                DispatchQueue.main.async { [weak self] in self?.onReadSelection?() }
                return nil
            }
            // Key + D -> AX tree dump (debug, swallowed)
            if keyCode == KeyCode.d {
                DispatchQueue.main.async { [weak self] in self?.onDumpAXTree?() }
                return nil
            }
            // Key + → -> Skip to next queued response — but only when there is something to
            // skip. Idle, it stays the app's (⌥→ = word jump).
            if keyCode == KeyCode.rightArrow, skipIsMeaningful() {
                DispatchQueue.main.async { [weak self] in self?.onSkipNext?() }
                return nil
            }
            // Anything else: passthrough, so normal modifier+key shortcuts still work.
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func scheduleHoldTimer() {
        holdTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.holdTimer = nil
            self.dispatch(self.gesture.handle(.holdTimerFired))
        }
        holdTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ModifierGesture.holdThreshold, execute: work)
    }

    /// The tap callback runs on the main run loop but not inside a main-actor context; hop the
    /// resulting action over so handlers see the same threading they always have.
    private func dispatch(_ action: ModifierGesture.Action) {
        guard action != .none else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch action {
            case .tap: self.onReadLatestOrToggle?()
            case .holdBegan: self.onPushToTalkBegan?()
            case .holdEnded: self.onPushToTalkEnded?()
            case .holdCancelled: self.onPushToTalkCancelled?()
            case .none: break
            }
        }
    }
}
