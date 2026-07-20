import AppKit
import ApplicationServices

/// Serial background executor for Accessibility IPC and pasteboard capture. AX calls into another
/// process are synchronous IPC that can stall for hundreds of ms (e.g. Chromium building its AX
/// tree), so they must not run on the main thread. A single global actor also means at most one
/// probe / copy-press / clipboard cycle runs at a time, so two extractions can never interleave
/// their pasteboard save-and-restore.
@globalActor
actor AXWorker {
    static let shared = AXWorker()
}

/// An AXUIElement is an immutable handle naming a UI element in another process — safe to retain
/// and pass between threads. The AX *calls* made through it are what need serializing, and those
/// run on AXWorker. Handles cross from AXWorker probes to main-actor bookkeeping (ConversationWatcher
/// state) and back again for the copy press.
extension AXUIElement: @retroactive @unchecked Sendable {}

/// Reads structure out of apps via the macOS Accessibility (AX) API.
///
/// Strategy is per-app because each chat client exposes a different AX tree shape.
/// Tree walks, button presses, and clipboard capture run on `AXWorker`; only the
/// NSWorkspace lookups (frontmost app) stay on the main actor.
final class AccessibilityReader {

    struct FrontApp {
        let bundleID: String?
        let localizedName: String?
        let pid: pid_t
    }

    @MainActor
    static func frontmost() -> FrontApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontApp(
            bundleID: app.bundleIdentifier,
            localizedName: app.localizedName,
            pid: app.processIdentifier
        )
    }

    /// Returns the AX dump of the frontmost app's focused window as a string.
    /// Used to figure out where each app puts its message text.
    @MainActor
    static func dumpFocusedWindow() -> String {
        guard let front = frontmost() else { return "[no frontmost app]" }
        let header = "Front app: \(front.localizedName ?? "?") (\(front.bundleID ?? "?")) pid=\(front.pid)\n"

        let appElement = AXUIElementCreateApplication(front.pid)

        // Force Chromium/Electron apps to expose their accessibility tree.
        // No-op for native apps; some respond to AXEnhancedUserInterface instead.
        enableManualAccessibility(on: appElement)

        var focusedWindow: AnyObject?
        let status = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard status == .success, let focusedWindow else {
            return header + "[no focused window — AX error \(status.rawValue)]"
        }

        let window = focusedWindow as! AXUIElement
        enableManualAccessibility(on: window)

        // Give Chromium a beat to populate the tree after enabling.
        Thread.sleep(forTimeInterval: 2.0)

        var out = header + "Window tree:\n"
        walk(window, depth: 0, into: &out, maxDepth: 40, maxChildrenPerLevel: 200)
        return out
    }

    /// Tells the target process to expose its full AX tree. For Chromium/Electron apps,
    /// this triggers the renderer to build the accessibility tree from the DOM.
    private static func enableManualAccessibility(on element: AXUIElement) {
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    // MARK: - Reading the latest assistant message

    struct ReadResult {
        let text: String
        let sourceApp: String
    }

    enum ReadError: Error, LocalizedError {
        case noFrontApp
        case unsupportedApp(String)
        case noFocusedWindow
        case noAssistantMessageFound
        case noReadableContent
        case copyFailed
        case noSelection

        var errorDescription: String? {
            switch self {
            case .noFrontApp: "No frontmost application."
            case .unsupportedApp(let id): "Reading not supported for \(id) yet."
            case .noFocusedWindow: "No focused window in the frontmost app."
            case .noAssistantMessageFound: "Couldn't find an assistant message to read."
            case .noReadableContent: "Nothing to read here — select text and press Right Cmd + S instead."
            case .copyFailed: "Couldn't copy the assistant message to the clipboard."
            case .noSelection: "Nothing is selected to read."
            }
        }
    }

    /// Read the currently selected text from the frontmost app.
    /// Tries the AX selected-text attribute first; falls back to a simulated Cmd+C + clipboard sniff
    /// for apps (terminals, some Electron apps) that don't expose selected text via AX.
    @MainActor
    static func readSelection() async throws -> ReadResult {
        guard let front = frontmost() else { throw ReadError.noFrontApp }
        let sourceApp = front.localizedName ?? front.bundleID ?? "?"

        // Strategy 1: AX selected text on the focused element.
        if let text = await axSelectedText(pid: front.pid), !text.isEmpty {
            return ReadResult(text: text, sourceApp: sourceApp)
        }

        // Strategy 2: simulate Cmd+C and read the clipboard, then restore.
        if let text = await copyViaCmdCAndCapture(), !text.isEmpty {
            return ReadResult(text: text, sourceApp: sourceApp)
        }

        throw ReadError.noSelection
    }

    @AXWorker
    private static func axSelectedText(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        let el = element as! AXUIElement
        var selected: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String else { return nil }
        return text
    }

    @AXWorker
    private static func copyViaCmdCAndCapture() -> String? {
        let pb = NSPasteboard.general
        let prior = pasteboardSnapshot(pb)
        let priorChangeCount = pb.changeCount

        guard let src = CGEventSource(stateID: .combinedSessionState) else { return nil }
        // Cmd down + C down + C up + Cmd up
        let cKeyDown = CGEvent(keyboardEventSource: src, virtualKey: 8 /* C */, keyDown: true)
        let cKeyUp = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false)
        cKeyDown?.flags = .maskCommand
        cKeyUp?.flags = .maskCommand
        cKeyDown?.post(tap: .cghidEventTap)
        cKeyUp?.post(tap: .cghidEventTap)

        // Poll briefly for clipboard to update.
        let deadline = Date().addingTimeInterval(0.6)
        var captured: String?
        while Date() < deadline {
            if pb.changeCount != priorChangeCount,
               let s = pb.string(forType: .string), !s.isEmpty {
                captured = s
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        restorePasteboard(pb, from: prior)
        return captured
    }

    /// Read the latest assistant message from the frontmost app.
    /// Supported in Slice 1b: Claude desktop and Claude.ai (any Chromium-based browser).
    @MainActor
    static func readLatest() async throws -> ReadResult {
        guard let front = frontmost() else { throw ReadError.noFrontApp }

        let sourceApp = front.localizedName ?? front.bundleID ?? "?"

        switch front.bundleID {
        case "com.anthropic.claudefordesktop",
             "com.apple.Safari",
             "com.google.Chrome",
             "company.thebrowser.Browser",   // Arc
             "company.thebrowser.dia",        // Dia
             "com.microsoft.edgemac",
             "org.mozilla.firefox",
             "com.brave.Browser":
            // Claude desktop / a Claude.ai tab: use the reliable marker-based strategies.
            // But the same browser could be on ChatGPT, Gemini, Perplexity, etc. — if the Claude
            // markers don't match, fall through to the generic "press the last Copy button" hunt.
            let text: String
            do {
                text = try await readClaudeStyle(pid: front.pid)
            } catch ReadError.noAssistantMessageFound {
                text = try await readGenericCopyButton(pid: front.pid)
            }
            return ReadResult(text: text, sourceApp: sourceApp)
        case "com.openai.codex":
            // Codex desktop: each turn has a "Copy message" button, but diffs render bare "Copy"
            // buttons below the message — so the generic last-Copy hunt grabs a diff. Use the
            // bespoke strategy that targets the latest assistant "Copy message".
            let text: String
            do {
                text = try await readCodexStyle(pid: front.pid)
            } catch ReadError.noAssistantMessageFound {
                text = try await readGenericCopyButton(pid: front.pid)
            }
            return ReadResult(text: text, sourceApp: sourceApp)
        default:
            // Any other app (ChatGPT desktop, Gemini desktop, other chat clients): best-effort.
            // Terminals have no per-message structure — they should use Read Selection instead.
            let text = try await readGenericCopyButton(pid: front.pid)
            return ReadResult(text: text, sourceApp: sourceApp)
        }
    }

    /// Best-effort Read Latest for apps without a bespoke strategy.
    ///
    /// Most chat UIs render a per-message "Copy" button. We walk the focused window's AX tree,
    /// collect every copy-style button in document order, and press the LAST one — in a
    /// top-to-bottom transcript that's almost always the newest message's copy control. The text
    /// lands on the pasteboard; the user's prior clipboard is restored.
    ///
    /// This is intentionally generic so new chat apps work with zero per-app code. When the generic
    /// guess grabs the wrong thing (e.g. a code-block copy button), we add a bespoke strategy for
    /// that specific app — same as `readClaudeStyle`.
    @AXWorker
    private static func readGenericCopyButton(pid: pid_t) throws -> String {
        guard let window = resolvedWindow(pid: pid) else { throw ReadError.noFocusedWindow }

        // Poll (up to 1.6s) for any copy-style button instead of a blind fixed sleep.
        let last = Self.poll(timeout: 1.6) { () -> AXUIElement? in
            var buttons: [AXUIElement] = []
            collectCopyButtons(window, into: &buttons)
            return buttons.last
        }
        guard let last else { throw ReadError.noReadableContent }
        return try pressCopyAndCaptureClipboard(last)
    }

    /// Collects buttons whose accessibility label looks like a "copy this message" control,
    /// in document order. Excludes obvious code-block / link copy buttons so the newest *message*
    /// copy button wins.
    private static func collectCopyButtons(_ element: AXUIElement, into out: inout [AXUIElement]) {
        if stringAttr(element, kAXRoleAttribute as CFString) == "AXButton" {
            let label = [
                stringAttr(element, kAXDescriptionAttribute as CFString),
                stringAttr(element, kAXTitleAttribute as CFString),
                stringAttr(element, kAXHelpAttribute as CFString)
            ].compactMap { $0?.lowercased() }.joined(separator: " ")

            if label.contains("copy"),
               !label.contains("code"),
               !label.contains("link"),
               !label.contains("url") {
                out.append(element)
            }
        }

        var children: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        guard status == .success, let array = children as? [AXUIElement] else { return }
        for child in array { collectCopyButtons(child, into: &out) }
    }

    /// Reads the latest assistant message by finding the per-message Copy button in the AX tree
    /// and programmatically pressing it. The message arrives on the system pasteboard as markdown.
    /// User's prior clipboard content is preserved across the operation.
    ///
    /// Works for Claude desktop (chat + Claude Code tabs) and Claude.ai in any browser.
    @AXWorker
    private static func readClaudeStyle(pid: pid_t) throws -> String {
        guard let window = resolvedWindow(pid: pid) else { throw ReadError.noFocusedWindow }

        // Poll (up to 1.6s) for a directly-visible copy button instead of a blind fixed sleep —
        // a warm Chromium tree resolves almost immediately.
        //   Strategy 1: marker-bounded — `Copy` / `Copy message` after the last "Claude responded:"
        //               marker (chat tab always; Code tab when its toolbar is expanded, which the
        //               newest assistant message's is).
        //   Strategy 2: legacy Code tab — "Copy message" immediately followed by "Pin as chapter".
        if let copyButton = Self.poll(timeout: 1.6, {
            findLatestAssistantCopyButton(in: window) ?? findLatestCodeTabAssistantCopyButton(in: window)
        }) {
            return try pressCopyAndCaptureClipboard(copyButton)
        }

        // Strategy 3: the newest Code-tab turn often has no "Claude responded:" heading, so take
        // the last copy/disclosure control after the final turn marker — controls follow their
        // message, so the last one belongs to the newest turn. If it's a collapsed "Show message
        // actions" disclosure, press it and wait for the revealed Copy message button.
        switch trailingTurnControl(in: window) {
        case .copy(let button):
            return try pressCopyAndCaptureClipboard(button)
        case .disclosure(let button):
            if AXUIElementPerformAction(button, kAXPressAction as CFString) == .success,
               let revealed = Self.poll(timeout: 1.5, { () -> AXUIElement? in
                   if case .copy(let element)? = trailingTurnControl(in: window) { return element }
                   return nil
               }) {
                return try pressCopyAndCaptureClipboard(revealed)
            }
        case nil:
            break
        }

        throw ReadError.noAssistantMessageFound
    }

    /// Codex desktop app (com.openai.codex). Turn layout:
    ///   user msg:      [text] [timestamp] [Button "Copy message"]
    ///   assistant msg: [content…] [Button "Copy"] [CheckBox "Good response"] ["Bad response"] ["Fork…"]
    /// So the *assistant's* copy control is the bare "Copy" button in its action row — identified by
    /// the "Good response" feedback checkbox that immediately follows it. "Copy message" is the user's
    /// prompt; bare "Copy" buttons inside code blocks render before the action row, so the assistant's
    /// message copy is the last "Copy" before the "Good response".
    @AXWorker
    private static func readCodexStyle(pid: pid_t) throws -> String {
        guard let window = resolvedWindow(pid: pid) else { throw ReadError.noFocusedWindow }

        // Poll (up to 1.6s) for the assistant Copy button instead of a blind fixed sleep.
        let copyButton = Self.poll(timeout: 1.6) { findLatestCodexAssistantCopyButton(in: window) }
        guard let copyButton else { throw ReadError.noAssistantMessageFound }
        return try pressCopyAndCaptureClipboard(copyButton)
    }

    /// Returns the assistant's "Copy" button for the latest assistant turn — the last bare "Copy"
    /// button immediately followed by a "Good response" feedback control. The user's "Copy message"
    /// button is deliberately ignored.
    private static func findLatestCodexAssistantCopyButton(in root: AXUIElement) -> AXUIElement? {
        var items: [CodexItem] = []
        collectCodexItems(root, into: &items)

        var lastAssistant: AXUIElement?
        var pendingCopy: AXUIElement?
        for item in items {
            switch item {
            case .assistantCopy(let element):
                pendingCopy = element
            case .goodResponse:
                if let pendingCopy { lastAssistant = pendingCopy }
                pendingCopy = nil
            }
        }
        return lastAssistant
    }

    private enum CodexItem {
        case assistantCopy(AXUIElement)
        case goodResponse
    }

    private static func collectCodexItems(_ element: AXUIElement, into out: inout [CodexItem]) {
        let role = stringAttr(element, kAXRoleAttribute as CFString)
        let desc = stringAttr(element, kAXDescriptionAttribute as CFString) ?? ""

        // Bare "Copy" = an assistant message/code copy. "Copy message" (user prompt) is skipped.
        if role == "AXButton", desc == "Copy" {
            out.append(.assistantCopy(element))
        } else if role == "AXCheckBox", desc == "Good response" {
            out.append(.goodResponse)
        }

        var children: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        guard status == .success, let array = children as? [AXUIElement] else { return }
        for child in array { collectCodexItems(child, into: &out) }
    }

    /// Walks the tree collecting Copy/Pin/Rewind buttons in document order, then finds the last
    /// "Copy message" that is immediately followed by a "Pin as chapter" (= assistant turn).
    private static func findLatestCodeTabAssistantCopyButton(in root: AXUIElement) -> AXUIElement? {
        var items: [CodeTabItem] = []
        collectCodeTabItems(root, into: &items)

        // Walk the list, pair each Copy with whatever immediately follows.
        var lastAssistantCopy: AXUIElement?
        for i in 0..<items.count {
            guard case .copyMessage(let element) = items[i] else { continue }
            // Look at the next non-copy marker.
            for j in (i + 1)..<items.count {
                switch items[j] {
                case .pinAsChapter:
                    lastAssistantCopy = element
                    break
                case .rewindToHere, .forkFromHere:
                    // This Copy belongs to a user message; skip.
                    break
                case .copyMessage:
                    // Another Copy before any marker — undecidable for this one; bail out of inner loop.
                    break
                }
                break
            }
        }
        return lastAssistantCopy
    }

    private enum CodeTabItem {
        case copyMessage(AXUIElement)
        case pinAsChapter
        case rewindToHere
        case forkFromHere
    }

    private static func collectCodeTabItems(_ element: AXUIElement, into out: inout [CodeTabItem]) {
        let role = stringAttr(element, kAXRoleAttribute as CFString)
        let desc = stringAttr(element, kAXDescriptionAttribute as CFString) ?? ""

        if role == "AXButton" {
            switch desc {
            case "Copy message":  out.append(.copyMessage(element))
            case "Rewind to here": out.append(.rewindToHere)
            case "Fork from here": out.append(.forkFromHere)
            default: break
            }
        } else if role == "AXCheckBox" && desc == "Pin as chapter" {
            out.append(.pinAsChapter)
        }

        var children: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        guard status == .success, let array = children as? [AXUIElement] else { return }
        for child in array { collectCodeTabItems(child, into: &out) }
    }

    /// Walks the AX tree, collecting markers and copy controls in document order.
    /// A turn's controls follow its content, so everything between the last "Claude responded:"
    /// marker and the next "You said:" marker (or end of tree) belongs to the latest assistant turn.
    private enum MarkerKind {
        case assistant
        case user
        case copy(AXUIElement)
        /// Collapsed "Show message actions" button (Claude Code tab). Pressing it reveals the
        /// turn's Copy message button.
        case disclosure(AXUIElement)
    }

    private static func findLatestAssistantCopyButton(in root: AXUIElement) -> AXUIElement? {
        var items: [MarkerKind] = []
        collectMarkers(root, into: &items)

        // Find last "assistant" index.
        guard let lastAssistantIdx = items.lastIndex(where: {
            if case .assistant = $0 { return true } else { return false }
        }) else {
            return nil
        }

        // Search forward from there for copy buttons. Stop at the next user marker.
        // Assistant messages put their copy button below their content, so the LAST copy
        // in the slice belongs to the latest assistant message.
        var foundCopy: AXUIElement?
        for item in items[(lastAssistantIdx + 1)...] {
            switch item {
            case .user: return foundCopy
            case .copy(let element): foundCopy = element
            case .assistant, .disclosure: continue
            }
        }
        return foundCopy
    }

    /// The newest Code-tab turn often renders WITHOUT its "You said:"/"Claude responded:" heading,
    /// so marker-bounded search can't see it. Fallback: scan past the LAST turn marker of either
    /// kind and take the last copy/disclosure control in document order — a turn's controls follow
    /// its content, so the last control in that unmarked tail belongs to the newest message.
    private enum TrailingControl {
        case copy(AXUIElement)
        case disclosure(AXUIElement)
    }

    private static func trailingTurnControl(in root: AXUIElement) -> TrailingControl? {
        var items: [MarkerKind] = []
        collectMarkers(root, into: &items)
        guard let lastMarkerIdx = items.lastIndex(where: {
            switch $0 {
            case .assistant, .user: return true
            case .copy, .disclosure: return false
            }
        }) else { return nil }

        var last: TrailingControl?
        for item in items[(lastMarkerIdx + 1)...] {
            switch item {
            case .copy(let element): last = .copy(element)
            case .disclosure(let element): last = .disclosure(element)
            case .assistant, .user: continue
            }
        }
        return last
    }

    private static func collectMarkers(_ element: AXUIElement, into out: inout [MarkerKind]) {
        let role = stringAttr(element, kAXRoleAttribute as CFString)
        let desc = stringAttr(element, kAXDescriptionAttribute as CFString)
        let title = stringAttr(element, kAXTitleAttribute as CFString) ?? ""
        let value = stringAttr(element, kAXValueAttribute as CFString) ?? ""

        if role == "AXHeading" {
            if title.hasPrefix(Self.assistantPrefix) || value.hasPrefix(Self.assistantPrefix) {
                out.append(.assistant)
            } else if title.hasPrefix(Self.userPrefix) || value.hasPrefix(Self.userPrefix) {
                out.append(.user)
            }
        }
        if role == "AXStaticText" {
            if value.hasPrefix(Self.assistantPrefix) {
                out.append(.assistant)
            } else if value.hasPrefix(Self.userPrefix) {
                out.append(.user)
            }
        }
        if role == "AXButton" {
            // Chat tab renders `desc="Copy"`; the Code tab's expanded toolbar renders
            // `desc="Copy message"`.
            if desc == "Copy" || desc == "Copy message" {
                out.append(.copy(element))
            } else if desc == "Show message actions" || title == "Show message actions" {
                out.append(.disclosure(element))
            }
        }

        var children: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        guard status == .success, let array = children as? [AXUIElement] else { return }
        for child in array { collectMarkers(child, into: &out) }
    }

    /// Repeatedly runs `probe` until it returns a non-nil value or `timeout` elapses, polling every
    /// `interval`. Returns as soon as the value is ready — so a warm AX tree resolves in ~one probe
    /// instead of always paying a fixed sleep. Worst case matches the old fixed wait.
    private static func poll<T>(timeout: TimeInterval, interval: TimeInterval = 0.05, _ probe: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let value = probe() { return value }
            if Date() >= deadline { return nil }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    /// Presses the given AXButton via the AX press action, captures the resulting pasteboard
    /// content, and restores the user's previous clipboard exactly as it was.
    @AXWorker
    private static func pressCopyAndCaptureClipboard(_ button: AXUIElement) throws -> String {
        let pb = NSPasteboard.general
        let prior = pasteboardSnapshot(pb)
        let priorChangeCount = pb.changeCount

        let pressResult = AXUIElementPerformAction(button, kAXPressAction as CFString)
        guard pressResult == .success else { throw ReadError.copyFailed }

        // Poll for the clipboard to update — Claude writes the message text as the Copy action.
        let deadline = Date().addingTimeInterval(1.5)
        var captured: String?
        while Date() < deadline {
            if pb.changeCount != priorChangeCount,
               let s = pb.string(forType: .string),
               !s.isEmpty {
                captured = s
                break
            }
            Thread.sleep(forTimeInterval: 0.03)
        }

        restorePasteboard(pb, from: prior)

        guard let captured else { throw ReadError.copyFailed }
        return captured
    }

    // MARK: - Pasteboard preservation

    /// Full snapshot of the pasteboard: every item with every type's data, so restore preserves
    /// images, files, and rich text — not just plain strings.
    private static func pasteboardSnapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            item.types.reduce(into: [:]) { acc, type in
                acc[type] = item.data(forType: type)
            }
        }
    }

    /// Puts the snapshot back, including restoring emptiness if the pasteboard held nothing.
    private static func restorePasteboard(_ pb: NSPasteboard, from snapshot: [[NSPasteboard.PasteboardType: Data]]) {
        pb.clearContents()
        guard !snapshot.isEmpty else { return }
        let items: [NSPasteboardItem] = snapshot.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(items)
    }

    // MARK: - Conversation Mode: clipboard-free probing

    /// Apps with reliable Claude-style marker/Copy strategies (Claude desktop + Claude.ai in browsers).
    static let claudeFamilyBundleIDs: Set<String> = [
        "com.anthropic.claudefordesktop",
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser",
        "company.thebrowser.dia", "com.microsoft.edgemac", "org.mozilla.firefox", "com.brave.Browser"
    ]
    /// Browsers — for these, Conversation Mode only reads when the active tab is an AI chat site.
    static let browserBundleIDs: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser",
        "company.thebrowser.dia", "com.microsoft.edgemac", "org.mozilla.firefox", "com.brave.Browser"
    ]
    /// Host fragments that mark an AI chat site (browser tab gating).
    static let aiSiteHosts: [String] = [
        "claude.ai", "chatgpt.com", "chat.openai.com", "gemini.google.com", "perplexity.ai"
    ]

    struct ProbeResult {
        let visibleText: String
        let hasCompletionControl: Bool
        let hasStopControl: Bool
        let copyButton: AXUIElement?
        let aiSiteOK: Bool
    }

    /// Resolve a usable window for a (possibly background) app: focused → main → first window.
    /// Enables manual accessibility so Chromium/Electron expose their tree.
    private static func resolvedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        enableManualAccessibility(on: app)
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] as [CFString] {
            var win: AnyObject?
            if AXUIElementCopyAttributeValue(app, attr, &win) == .success, let win {
                let w = win as! AXUIElement
                enableManualAccessibility(on: w)
                return w
            }
        }
        var windows: AnyObject?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
           let arr = windows as? [AXUIElement], let first = arr.first {
            enableManualAccessibility(on: first)
            return first
        }
        return nil
    }

    /// Per-app strategy to locate the latest assistant Copy button (no press). Shared by the manual
    /// read path's intent and the Conversation Mode probe.
    private static func latestAssistantCopyButton(window: AXUIElement, bundleID: String?) -> AXUIElement? {
        if let id = bundleID, claudeFamilyBundleIDs.contains(id) {
            return findLatestAssistantCopyButton(in: window) ?? findLatestCodeTabAssistantCopyButton(in: window)
        }
        if bundleID == "com.openai.codex" {
            return findLatestCodexAssistantCopyButton(in: window)
        }
        var buttons: [AXUIElement] = []
        collectCopyButtons(window, into: &buttons)
        return buttons.last
    }

    /// LIGHTWEIGHT, CLIPBOARD-FREE probe used by ConversationWatcher every tick.
    /// One bounded tree walk. No Thread.sleep, no AXPress, no pasteboard access.
    @AXWorker
    static func probeLatestAssistant(pid: pid_t, bundleID: String?) -> ProbeResult? {
        guard let window = resolvedWindow(pid: pid) else { return nil }
        let copyButton = latestAssistantCopyButton(window: window, bundleID: bundleID)
        let visibleText = latestAssistantVisibleText(window: window, bundleID: bundleID)
        let hasStop = hasStopGeneratingControl(in: window)
        let siteOK = aiSiteOK(window: window, bundleID: bundleID)
        return ProbeResult(
            visibleText: visibleText,
            hasCompletionControl: copyButton != nil,
            hasStopControl: hasStop,
            copyButton: copyButton,
            aiSiteOK: siteOK
        )
    }

    /// Heavy path: press an already-resolved Copy button and capture the markdown. Run ONCE per
    /// completed response. Reuses pressCopyAndCaptureClipboard (saves/restores prior clipboard).
    @AXWorker
    static func extractText(from copyButton: AXUIElement) throws -> String {
        try pressCopyAndCaptureClipboard(copyButton)
    }

    /// Plain text of the latest assistant turn, read directly from AXStaticText (no clipboard).
    private static func latestAssistantVisibleText(window: AXUIElement, bundleID: String?) -> String {
        if let id = bundleID, claudeFamilyBundleIDs.contains(id),
           let bounded = boundedAssistantText(window: window), !bounded.isEmpty {
            return bounded
        }
        var nodes: [TextNode] = []
        collectTextNodes(window, into: &nodes, inApplicationStatus: false, depth: 0, maxDepth: 60)
        return nodes.filter { !$0.inApplicationStatus }.map { $0.text }.suffix(40).joined(separator: " ")
    }

    /// Claude-style: concatenated static text between the last assistant marker and the next user
    /// marker (or end of tree).
    private static func boundedAssistantText(window: AXUIElement) -> String? {
        var items: [BoundItem] = []
        collectBoundItems(window, into: &items)
        guard let lastAssistant = items.lastIndex(where: { if case .assistant = $0 { return true }; return false })
        else { return nil }
        var out: [String] = []
        for item in items[(lastAssistant + 1)...] {
            switch item {
            case .user: return out.joined(separator: " ")
            case .text(let s): out.append(s)
            case .assistant: continue
            }
        }
        return out.joined(separator: " ")
    }

    private enum BoundItem { case assistant, user, text(String) }

    private static func collectBoundItems(_ element: AXUIElement, into out: inout [BoundItem]) {
        let role = stringAttr(element, kAXRoleAttribute as CFString)
        let title = stringAttr(element, kAXTitleAttribute as CFString) ?? ""
        let value = stringAttr(element, kAXValueAttribute as CFString) ?? ""
        if role == "AXHeading" || role == "AXStaticText" {
            if title.hasPrefix(assistantPrefix) || value.hasPrefix(assistantPrefix) {
                out.append(.assistant)
            } else if title.hasPrefix(userPrefix) || value.hasPrefix(userPrefix) {
                out.append(.user)
            } else if role == "AXStaticText", !value.isEmpty {
                out.append(.text(value))
            }
        }
        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let array = children as? [AXUIElement] else { return }
        for child in array { collectBoundItems(child, into: &out) }
    }

    /// True if a "Stop generating"-style control is present (assistant still streaming).
    private static func hasStopGeneratingControl(in root: AXUIElement) -> Bool {
        if stringAttr(root, kAXRoleAttribute as CFString) == "AXButton" {
            let label = [
                stringAttr(root, kAXDescriptionAttribute as CFString),
                stringAttr(root, kAXTitleAttribute as CFString),
                stringAttr(root, kAXHelpAttribute as CFString)
            ].compactMap { $0?.lowercased() }.joined(separator: " ")
            if label.contains("stop"),
               label.contains("generat") || label.contains("respond") || label.contains("streaming") {
                return true
            }
        }
        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &children) == .success,
              let array = children as? [AXUIElement] else { return false }
        for child in array where hasStopGeneratingControl(in: child) { return true }
        return false
    }

    /// For browsers, only read when the active tab is an AI chat site. Dedicated apps: always true.
    private static func aiSiteOK(window: AXUIElement, bundleID: String?) -> Bool {
        guard let id = bundleID, browserBundleIDs.contains(id) else { return true }
        let title = (stringAttr(window, kAXTitleAttribute as CFString) ?? "").lowercased()
        if aiSiteHosts.contains(where: { title.contains($0) }) { return true }
        if title.contains("claude") || title.contains("chatgpt")
            || title.contains("gemini") || title.contains("perplexity") { return true }
        if let url = documentURLString(in: window)?.lowercased(),
           aiSiteHosts.contains(where: { url.contains($0) }) { return true }
        return false
    }

    /// Best-effort active-tab URL: AXDocument on the window, else a bounded search of the tree.
    private static func documentURLString(in window: AXUIElement) -> String? {
        if let doc = stringAttr(window, kAXDocumentAttribute as CFString), !doc.isEmpty { return doc }
        return findDocumentURL(window, depth: 0, maxDepth: 12)
    }

    private static func findDocumentURL(_ element: AXUIElement, depth: Int, maxDepth: Int) -> String? {
        if depth > maxDepth { return nil }
        if let doc = stringAttr(element, kAXDocumentAttribute as CFString), !doc.isEmpty { return doc }
        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let array = children as? [AXUIElement] else { return nil }
        for child in array {
            if let found = findDocumentURL(child, depth: depth + 1, maxDepth: maxDepth) { return found }
        }
        return nil
    }

    private static let assistantPrefix = "Claude responded: "
    private static let userPrefix = "You said: "

    private struct TextNode {
        let text: String
        let depth: Int
        let inApplicationStatus: Bool
    }

    /// Depth-first walk of the AX tree, collecting AXStaticText values in document order.
    /// Tracks tree depth and whether we're inside an AXApplicationStatus group (tool-call indicator).
    private static func collectTextNodes(_ element: AXUIElement, into out: inout [TextNode], inApplicationStatus: Bool, depth: Int, maxDepth: Int) {
        if depth > maxDepth { return }

        let role = stringAttr(element, kAXRoleAttribute as CFString)
        let subrole = stringAttr(element, kAXSubroleAttribute as CFString)
        let isStatusGroup = subrole == "AXApplicationStatus"
        let inStatus = inApplicationStatus || isStatusGroup

        if role == "AXStaticText" {
            if let value = stringAttr(element, kAXValueAttribute as CFString) {
                out.append(TextNode(text: value, depth: depth, inApplicationStatus: inStatus))
            }
        }

        var children: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        guard status == .success, let array = children as? [AXUIElement] else { return }
        for child in array {
            collectTextNodes(child, into: &out, inApplicationStatus: inStatus, depth: depth + 1, maxDepth: maxDepth)
        }
    }

    /// Save the dump under ~/Library/Application Support/Yapper/ax-dumps/ for inspection.
    @MainActor
    @discardableResult
    static func saveDumpForFrontmost() -> URL? {
        let dump = dumpFocusedWindow()
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = support.appendingPathComponent("Yapper/ax-dumps", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("dump-\(stamp).txt")
        do {
            try dump.write(to: url, atomically: true, encoding: .utf8)
            Log.ax.info("AX dump saved: \(url.path, privacy: .public)")
            return url
        } catch {
            Log.ax.error("Failed to save AX dump: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Tree walker

    private static func walk(_ element: AXUIElement, depth: Int, into out: inout String, maxDepth: Int, maxChildrenPerLevel: Int) {
        if depth > maxDepth { return }
        let indent = String(repeating: "  ", count: depth)

        let role = stringAttr(element, kAXRoleAttribute as CFString) ?? "?"
        let subrole = stringAttr(element, kAXSubroleAttribute as CFString)
        let identifier = stringAttr(element, kAXIdentifierAttribute as CFString)
        let title = stringAttr(element, kAXTitleAttribute as CFString)
        let description = stringAttr(element, kAXDescriptionAttribute as CFString)
        let value = stringAttr(element, kAXValueAttribute as CFString)
        let help = stringAttr(element, kAXHelpAttribute as CFString)

        var line = "\(indent)[\(role)"
        if let subrole { line += " :\(subrole)" }
        if let identifier, !identifier.isEmpty { line += " #\(identifier)" }
        line += "]"
        if let title, !title.isEmpty { line += " title=\"\(snippet(title))\"" }
        if let description, !description.isEmpty { line += " desc=\"\(snippet(description))\"" }
        if let help, !help.isEmpty { line += " help=\"\(snippet(help))\"" }
        if let value, !value.isEmpty { line += " value=\"\(snippet(value))\"" }
        out += line + "\n"

        var children: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        guard status == .success, let array = children as? [AXUIElement] else { return }
        for child in array.prefix(maxChildrenPerLevel) {
            walk(child, depth: depth + 1, into: &out, maxDepth: maxDepth, maxChildrenPerLevel: maxChildrenPerLevel)
        }
    }

    private static func stringAttr(_ element: AXUIElement, _ attr: CFString) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attr, &value) == .success else { return nil }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private static func snippet(_ s: String, limit: Int = 200) -> String {
        let one = s.replacingOccurrences(of: "\n", with: "\\n")
        if one.count <= limit { return one }
        return String(one.prefix(limit)) + "…"
    }
}
