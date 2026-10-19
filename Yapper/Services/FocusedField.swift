import AppKit
import ApplicationServices

/// The element that has keyboard focus in the frontmost app, read through Accessibility.
///
/// Used to check that a paste landed, and to watch the field afterwards for the user's edits.
/// Every read is IPC into another process, so all of it runs on `AXWorker`.
struct FocusedField: Sendable {
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String?
    let role: String?

    /// Roles that take typed text. Web and Electron composers report AXTextArea or AXTextField;
    /// some expose only AXGroup with an editable flag, which `isTextInput` also accepts.
    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    @AXWorker
    static func current() -> FocusedField? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // Chromium and Electron build their AX tree only when asked. This flag is the quiet way
        // to ask; AXEnhancedUserInterface also works but changes window animation in some apps.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        return FocusedField(element: element, pid: app.processIdentifier,
                            bundleID: app.bundleIdentifier, role: string(element, kAXRoleAttribute))
    }

    /// Password fields never get read or watched.
    var isSecure: Bool {
        role == "AXSecureTextField"
    }

    @AXWorker
    var isTextInput: Bool {
        if let role, Self.textRoles.contains(role) { return true }
        var editable: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editable) == .success,
           let flag = editable as? Bool { return flag }
        return false
    }

    /// The field's whole text, or nil when the app doesn't expose it.
    @AXWorker
    var value: String? {
        guard !isSecure else { return nil }
        return Self.string(element, kAXValueAttribute)
    }

    /// The field's text before and after the cursor (or the selection a paste will replace),
    /// trimmed to what fitting needs. Nil when the app doesn't expose it.
    @AXWorker
    func cursorContext() -> (before: String, after: String)? {
        guard !isSecure, let value else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
        let ns = value as NSString
        guard range.location >= 0, range.location + range.length <= ns.length else { return nil }
        let before = ns.substring(to: range.location)
        let after = ns.substring(from: range.location + range.length)
        return (String(before.suffix(300)), String(after.prefix(100)))
    }

    /// Put keyboard focus back on this element, after its app was brought forward again.
    @AXWorker
    func refocus() {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    @AXWorker
    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? String
    }
}
