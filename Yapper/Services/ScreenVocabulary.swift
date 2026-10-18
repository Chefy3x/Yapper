import AppKit
import ApplicationServices

/// Words on screen that Whisper is likely to misspell: the names, products and jargon in the
/// window you're dictating into. They go into Whisper's prompt next to your own vocabulary, so
/// "reply to Quinlan about the WhisperKit PR" comes out spelled the way the thread spells it.
///
/// Read once per turn while you talk, from the focused window only. Nothing leaves the Mac and
/// nothing is stored; the words are gone when the turn ends.
enum ScreenVocabulary {
    /// Words fed to Whisper per turn. The prompt shares its budget with your own terms, which win.
    static let maxWords = 25
    /// Bounds on the Accessibility walk, so a huge document can't stall the turn.
    static let maxCharacters = 30_000
    static let maxNodes = 3_000
    static let maxDepth = 40
    static let walkBudget: TimeInterval = 0.25

    /// Text of the frontmost window, or "" when it can't be read.
    @AXWorker
    static func visibleText() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return "" }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return "" }

        var pieces: [String] = []
        var characters = 0
        var nodes = 0
        let deadline = Date().addingTimeInterval(walkBudget)
        var stack: [(AXUIElement, Int)] = [(window as! AXUIElement, 0)]
        while let (element, depth) = stack.popLast() {
            nodes += 1
            if nodes > maxNodes || characters > maxCharacters || Date() > deadline { break }
            let role = string(element, kAXRoleAttribute)
            if role == "AXSecureTextField" { continue }
            if role == "AXStaticText" || role == "AXTextArea" || role == "AXTextField" || role == "AXHeading" {
                if let text = string(element, kAXValueAttribute), !text.isEmpty {
                    let piece = String(text.suffix(maxCharacters - characters))
                    pieces.append(piece)
                    characters += piece.count
                }
            }
            if role == "AXLink" || role == "AXButton", let title = string(element, kAXTitleAttribute), !title.isEmpty {
                pieces.append(title)
                characters += title.count
            }
            guard depth < maxDepth else { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                // Reversed so the walk pops children in reading order.
                for child in list.reversed() { stack.append((child, depth + 1)) }
            }
        }
        return pieces.joined(separator: "\n")
    }

    @AXWorker
    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    /// The words worth biasing Whisper toward, most frequent first. A word qualifies when Whisper
    /// would have to guess its spelling: camelCase or letters-with-digits ("WhisperKit", "GPT5"),
    /// a capitalised word the dictionary doesn't know (most names), an acronym, or an unknown
    /// lowercase word that shows up more than once (a command, a handle).
    static func candidates(in text: String, limit: Int = maxWords,
                           isDictionaryWord: (String) -> Bool) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9'’\-]*[A-Za-z0-9]"#) else { return [] }
        var counts: [String: Int] = [:]
        var order: [String] = []
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var word = ns.substring(with: match.range)
            for suffix in ["'s", "’s"] where word.hasSuffix(suffix) { word.removeLast(2) }
            word = word.trimmingCharacters(in: CharacterSet(charactersIn: "-'’"))
            guard (2...30).contains(word.count) else { continue }
            if counts[word] == nil { order.append(word) }
            counts[word, default: 0] += 1
            if order.count >= 1_500 { break }
        }

        var picked: [(word: String, count: Int, index: Int)] = []
        var seenLower: Set<String> = []
        for (index, word) in order.enumerated() {
            let count = counts[word] ?? 0
            guard qualifies(word, count: count, isDictionaryWord: isDictionaryWord) else { continue }
            guard seenLower.insert(word.lowercased()).inserted else { continue }
            picked.append((word, count, index))
        }
        return picked
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.index < $1.index }
            .prefix(limit)
            .map(\.word)
    }

    private static func qualifies(_ word: String, count: Int, isDictionaryWord: (String) -> Bool) -> Bool {
        let letters = word.filter(\.isLetter)
        let hasDigit = word.contains(where: \.isNumber)
        let first = word.first!
        let hasInnerCapital = word.dropFirst().contains(where: \.isUppercase) && word.contains(where: \.isLowercase)
        if hasDigit { return letters.count >= 2 }
        if hasInnerCapital { return word.count >= 4 }
        if letters.allSatisfy(\.isUppercase) {
            // Acronyms: short, repeated, not a shouted ordinary word.
            return (2...6).contains(word.count) && count >= 2 && !isDictionaryWord(word.lowercased())
        }
        guard word.count >= 3 else { return false }
        if first.isUppercase { return !isDictionaryWord(word) && !isDictionaryWord(word.lowercased()) }
        return count >= 2 && word.count >= 4 && !isDictionaryWord(word)
    }
}

/// The system spelling dictionary, as the "is this an ordinary word?" test for screen words and
/// learned edits. AppKit's spell checker isn't thread-safe, so it's main-actor only.
@MainActor
enum WordKnowledge {
    private static var cache: [String: Bool] = [:]

    static func isDictionaryWord(_ word: String) -> Bool {
        if let known = cache[word] { return known }
        let checker = NSSpellChecker.shared
        let range = checker.checkSpelling(of: word, startingAt: 0, language: "en", wrap: false,
                                          inSpellDocumentWithTag: 0, wordCount: nil)
        let known = range.location == NSNotFound
        if cache.count > 5_000 { cache.removeAll() }
        cache[word] = known
        return known
    }
}
