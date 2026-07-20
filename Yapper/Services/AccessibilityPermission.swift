import AppKit
import ApplicationServices

enum AccessibilityPermission {
    /// Returns true when the process is already trusted. Does NOT prompt.
    static func isGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Returns true when trusted. If `prompt` is true, macOS shows the standard prompt the first time.
    @discardableResult
    static func requestIfNeeded(prompt: Bool = true) -> Bool {
        // The CFString constant is Sendable-unsafe under Swift 6, but its value is stable.
        let key = "AXTrustedCheckOptionPrompt"
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
