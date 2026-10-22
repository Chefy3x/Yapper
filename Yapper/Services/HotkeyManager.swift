import AppKit
import CoreGraphics

/// Watches the keyboard via CGEventTap for Yapper's gestures on the **Yapper key** — one modifier
/// (Right ⌥ by default, see `YapperKey`) that is the whole control surface:
///   1. Tap (press + release, no other key, < 400ms)        -> readLatestOrPauseToggle
///   2. Hold (> 450ms, nothing else touched)                -> pushToTalk began / ended
///   3. Key + Enter                                         -> toggleConversationMode
///      (mid-talk it finishes the dictation instead, like a release)
///   4. Key + S                                             -> readSelection
///   5. Key + →                                             -> skipNext (only while playing/queued)
///   6. Key + D                                             -> AX tree dump (debug)
///   7. Key + V                                             -> paste the last transcript again
///   8. Key + Space, while holding to talk                  -> lock the mic (release, keep talking;
///      the next press of the key finishes)
/// Chords 3, 4, 6 and 7 are swallowed (7 not when the key is Right ⌘, where it's plain paste) so the focused app never sees them. Chord 5 is swallowed only
/// when a skip means something; otherwise it passes through, because ⌥→ is word-jump in every
/// text field and stealing it would be a daily paper cut. Anything else pressed while the key
/// is held passes through unmodified, so it still works as a normal modifier.
///
/// Shortcuts recorded in Settings → Hotkeys (`shortcuts`), keys or a mouse's extra buttons, are
/// extra ways into the tap, the talk hold and chords 3–7, any number per action; the chords keep
/// working alongside them. A Talk
/// shortcut reports its press and, with how long it was held, its release (see `TalkShortcut`).
///
/// Requires Accessibility permission. Without it, install() succeeds-but-does-nothing because the
/// tap will be disabled by the system.
@MainActor
final class HotkeyManager {
    private typealias KeyCode = KeyShortcut.Code

    var onReadLatestOrToggle: (() -> Void)?
    /// Hold the Yapper key past the tap window: the mic opens. Release: transcribe. Any other key
    /// or a click during the hold: the user meant a chord, cancel silently.
    var onPushToTalkBegan: (() -> Void)?
    var onPushToTalkEnded: (() -> Void)?
    var onPushToTalkCancelled: (() -> Void)?
    /// The key went down — before anyone knows whether it's a tap or a hold. Voice In uses it to
    /// open the mic early. Every press that never becomes a hold ends in `onKeyAbandoned`.
    var onKeyDown: (() -> Void)?
    var onKeyAbandoned: (() -> Void)?
    var onReadSelection: (() -> Void)?
    var onToggleConversationMode: (() -> Void)?
    var onDumpAXTree: (() -> Void)?
    var onSkipNext: (() -> Void)?
    var onRepasteLast: (() -> Void)?
    /// Space during a talk hold: keep the mic open after the key comes up.
    var onLockRequested: (() -> Void)?
    /// A recorded Talk shortcut went down, and came back up after `heldFor` seconds.
    var onTalkShortcutPressed: (() -> Void)?
    var onTalkShortcutReleased: ((TimeInterval) -> Void)?
    /// A recorded Keep listening shortcut: lock a talk in progress, finish a locked one, or
    /// start one already locked.
    var onKeepListening: (() -> Void)?
    /// Answers "is a talk hold in progress?" — decides whether Space is Yapper's or the app's.
    var canLockMic: () -> Bool = { false }
    /// Answers "would a skip do anything right now?" — playing or queued. Decides whether
    /// Key + → is Yapper's or the app's.
    var skipIsMeaningful: () -> Bool = { false }

    /// Shortcuts recorded in Settings, on top of the chords. Set by AppState.
    var shortcuts: [HotkeyAction: [KeyShortcut]] = [:]
    /// True while Settings is recording a shortcut: every key goes to the recorder untouched.
    var isRecordingShortcut = false

    /// Which modifier is the Yapper key. Set from Settings by AppState; takes effect immediately.
    var key: YapperKey = .default {
        didSet {
            if gesture.isDown { notifyAbandoned() }
            gesture = ModifierGesture(); holdTimer?.cancel(); holdTimer = nil
        }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Tap-versus-hold state machine (pure, unit-tested) + the timer that fires its hold event.
    private var gesture = ModifierGesture()
    private var holdTimer: DispatchWorkItem?
    /// The Talk shortcut's key or mouse button while it is down, and since when. Its repeats
    /// and its release are Yapper's, so the app under it never sees a stray key.
    private var talkDown: (code: Int64, isMouse: Bool, at: Date)?
    /// Mouse buttons whose press was a shortcut: their release is swallowed too.
    private var heldShortcutButtons: Set<Int64> = []

    func install() {
        guard eventTap == nil else { return }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue)

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
                    DispatchQueue.main.async { [weak self] in self?.onKeyDown?() }
                    scheduleHoldTimer()
                } else {
                    holdTimer?.cancel()
                    holdTimer = nil
                    let action = gesture.handle(.commandUp)
                    if action != .holdEnded { notifyAbandoned() }
                    dispatch(action)
                }
            }
            return Unmanaged.passUnretained(event)

        case .otherMouseDown:
            // A mouse's extra button recorded as a shortcut: Yapper's, like a key.
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            if !isRecordingShortcut,
               let action = KeyShortcut.action(forMouseButton: button, flags: flags, in: shortcuts),
               action != .skipNext || skipIsMeaningful() {
                heldShortcutButtons.insert(button)
                fire(action, code: button, isMouse: true)
                return nil
            }
            fallthrough

        case .leftMouseDown, .rightMouseDown:
            // A click while the key is held (⌥-click, ⌥-drag, …) is aimed at the focused app —
            // releasing right after must NOT count as a tap, and a hold can't start from it.
            // Once the hold has begun, a click leaves the mic open: the user is clicking into
            // the field they're dictating to.
            if gesture.isDown, !gesture.holding { notifyAbandoned() }
            dispatch(gesture.handle(.mouseDown))
            return Unmanaged.passUnretained(event)

        case .keyDown:
            // Settings is recording a shortcut: let the key reach it, but don't let a held
            // Yapper key turn it into a chord or count its release as a tap.
            if isRecordingShortcut {
                if gesture.isDown { notifyAbandoned(); dispatch(gesture.handle(.otherKeyDown)) }
                return Unmanaged.passUnretained(event)
            }
            // The Talk shortcut held down auto-repeats; the repeats are not new presses.
            if let down = talkDown, !down.isMouse, keyCode == down.code,
               event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return nil
            }
            // A recorded shortcut wins over everything, held Yapper key or not.
            if let action = KeyShortcut.action(for: keyCode, flags: flags, in: shortcuts),
               action != .skipNext || skipIsMeaningful() {
                fire(action, code: keyCode, isMouse: false)
                return nil
            }
            // If the Yapper key is held, watch for our chords. Otherwise pass through.
            guard gesture.isDown else {
                return Unmanaged.passUnretained(event)
            }
            // Key + Space mid-hold: lock the mic (swallowed). The hold itself carries on, so
            // releasing the key ends the hold without ending the dictation.
            if keyCode == KeyCode.space, canLockMic() {
                DispatchQueue.main.async { [weak self] in self?.onLockRequested?() }
                return nil
            }
            // Return mid-talk: finish the dictation like a release, and swallow the Return —
            // Yapper never presses it. It is not the Conversation Mode chord here: someone five
            // seconds into talking who hits Return wants their words, not a mode switch.
            if keyCode == KeyCode.returnKey || keyCode == KeyCode.keypadEnter, gesture.holding {
                dispatch(gesture.handle(.finishKeyDown))
                return nil
            }
            // Any keyDown while the key is held cancels the pending "tap" interpretation
            // (and an in-progress hold-to-talk). It's a chord or ⌥-typing, never dictation.
            notifyAbandoned()
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
            // Key + V -> paste the last transcript again (swallowed). With Right ⌘ as the Yapper
            // key that chord is the system's own paste, so it stays the app's.
            if keyCode == KeyCode.v, key != .rightCommand {
                DispatchQueue.main.async { [weak self] in self?.onRepasteLast?() }
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

        case .keyUp, .otherMouseUp:
            // The Talk shortcut coming up: hold-to-talk ends, a quick press keeps listening.
            // Matched on the key or button alone, since the modifiers may already be up.
            let isMouse = type == .otherMouseUp
            let code = isMouse ? event.getIntegerValueField(.mouseEventButtonNumber) : keyCode
            let wasShortcutButton = isMouse && heldShortcutButtons.remove(code) != nil
            guard let down = talkDown, down.isMouse == isMouse, down.code == code else {
                return wasShortcutButton ? nil : Unmanaged.passUnretained(event)
            }
            talkDown = nil
            let heldFor = Date().timeIntervalSince(down.at)
            DispatchQueue.main.async { [weak self] in self?.onTalkShortcutReleased?(heldFor) }
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// A recorded shortcut went down, by key or mouse button. The caller swallows the event.
    private func fire(_ action: HotkeyAction, code: Int64, isMouse: Bool) {
        // Keep listening mid-hold is Space: the hold carries on, so it must not cancel it.
        let locksHold = action == .keepListening && canLockMic()
        if gesture.isDown, !locksHold { notifyAbandoned(); dispatch(gesture.handle(.otherKeyDown)) }
        if action == .talk {
            talkDown = (code, isMouse, Date())
            DispatchQueue.main.async { [weak self] in self?.onTalkShortcutPressed?() }
        } else {
            DispatchQueue.main.async { [weak self] in self?.perform(action) }
        }
    }

    private func perform(_ action: HotkeyAction) {
        switch action {
        case .readLatest:         onReadLatestOrToggle?()
        case .talk:               onTalkShortcutPressed?()
        case .keepListening:      onKeepListening?()
        case .readSelection:      onReadSelection?()
        case .repasteLast:        onRepasteLast?()
        case .toggleConversation: onToggleConversationMode?()
        case .skipNext:           onSkipNext?()
        case .dumpAXTree:         onDumpAXTree?()
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

    /// Queued on main like `dispatch`, so it lands in event order relative to the gesture's
    /// own actions. Idempotent on the receiving side.
    private func notifyAbandoned() {
        DispatchQueue.main.async { [weak self] in self?.onKeyAbandoned?() }
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
