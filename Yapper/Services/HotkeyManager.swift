import AppKit
import CoreGraphics

/// Watches the keyboard via CGEventTap to recognise Yapper's three gestures on the Right Command key:
///   1. Tap Right Cmd (press + release, no other key, < 400ms)  -> readLatestOrPauseToggle
///   2. Right Cmd + Enter                                       -> toggleConversationMode
///   3. Right Cmd + S                                           -> readSelection
/// Anything else (Right Cmd held while pressing any other key) is passed through unmodified, so
/// the right Command key still works as a normal modifier for app shortcuts.
///
/// Requires Accessibility permission. Without it, install() succeeds-but-does-nothing because the
/// tap will be disabled by the system.
@MainActor
final class HotkeyManager {
    // Carbon virtual key codes
    private enum KeyCode {
        static let rightCommand: Int64 = 54
        static let s: Int64 = 1
        static let d: Int64 = 2
        static let returnKey: Int64 = 36
        static let keypadEnter: Int64 = 76
        static let rightArrow: Int64 = 124
    }

    private static let tapThreshold: TimeInterval = 0.4

    var onReadLatestOrToggle: (() -> Void)?
    var onReadSelection: (() -> Void)?
    var onToggleConversationMode: (() -> Void)?
    var onDumpAXTree: (() -> Void)?
    var onSkipNext: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // State machine for tap detection
    private var rightCmdDownAt: Date?
    private var rightCmdConsumedByCombo: Bool = false

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
        Log.hotkey.info("HotkeyManager installed (Right Cmd tap, Right Cmd+S, Right Cmd+Enter).")
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
            if keyCode == KeyCode.rightCommand {
                // Right Command's "down" vs "up" is encoded in the .maskCommand bit at the moment of flagsChanged.
                let isDown = flags.contains(.maskCommand)
                if isDown {
                    rightCmdDownAt = Date()
                    rightCmdConsumedByCombo = false
                } else {
                    // Right Cmd just released.
                    if !rightCmdConsumedByCombo,
                       let downAt = rightCmdDownAt,
                       Date().timeIntervalSince(downAt) < Self.tapThreshold {
                        DispatchQueue.main.async { [weak self] in
                            self?.onReadLatestOrToggle?()
                        }
                    }
                    rightCmdDownAt = nil
                    rightCmdConsumedByCombo = false
                }
            }
            return Unmanaged.passUnretained(event)

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // A click while Right Cmd is held (Cmd+click a link, Cmd+select, …) is a combo
            // aimed at the focused app — releasing Cmd right after must NOT count as a tap.
            if rightCmdDownAt != nil { rightCmdConsumedByCombo = true }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            // If Right Cmd is held, watch for our combos. Otherwise pass through.
            guard rightCmdDownAt != nil else {
                return Unmanaged.passUnretained(event)
            }
            // Any keyDown while Right Cmd is held cancels the pending "tap" interpretation.
            rightCmdConsumedByCombo = true

            // Right Cmd + Enter -> Conversation Mode toggle (suppress so the focused app doesn't see ⌘↩)
            if keyCode == KeyCode.returnKey || keyCode == KeyCode.keypadEnter {
                DispatchQueue.main.async { [weak self] in self?.onToggleConversationMode?() }
                return nil
            }
            // Right Cmd + S -> Read Selection (suppress to avoid ⌘S "Save" in focused app)
            if keyCode == KeyCode.s {
                DispatchQueue.main.async { [weak self] in self?.onReadSelection?() }
                return nil
            }
            // Right Cmd + D -> AX tree dump (debug)
            if keyCode == KeyCode.d {
                DispatchQueue.main.async { [weak self] in self?.onDumpAXTree?() }
                return nil
            }
            // Right Cmd + → -> Skip to next queued response (suppress so the app doesn't see ⌘→)
            if keyCode == KeyCode.rightArrow {
                DispatchQueue.main.async { [weak self] in self?.onSkipNext?() }
                return nil
            }
            // Anything else: passthrough, so normal Cmd+letter shortcuts still work via Right Cmd.
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
