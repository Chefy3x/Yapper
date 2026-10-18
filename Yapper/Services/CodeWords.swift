import Foundation

/// What a turn read off the focused window: words to bias the decode toward, and the code
/// names (identifiers and file names) to type the way the code spells them.
struct ScreenReading: Sendable, Equatable {
    var words: [String] = []
    var identifiers: [String] = []
    /// The app takes `@file` mentions (Cursor, Claude, a terminal running Claude Code…).
    var tagsFiles = false

    static let empty = ScreenReading()
}

/// Variables and file names for when you dictate code. In an editor, a terminal or an AI chat,
/// the names on screen are what you'll say: "check user id in the session store" types
/// `check userId in the SessionStore`, and "look at app state dot swift" types
/// `look at @AppState.swift` where the app takes @ mentions.
///
/// Only names that are on screen are used, and only ones made of two or more words, so a
/// one-word name never swallows an ordinary word. Nothing is stored; the names go with the turn.
enum CodeWords {
    /// Names kept per turn, most frequent first.
    static let maxIdentifiers = 400

    // MARK: Apps

    private static let editors = ["com.microsoft.vscode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
                                  "dev.zed.zed", "com.apple.dt.xcode", "com.jetbrains.", "com.google.android.studio",
                                  "com.sublimetext.", "com.panic.nova", "com.vscodium", "com.cursor"]
    private static let aiChats = ["com.anthropic.claudefordesktop", "com.openai.codex", "com.openai.chat"]
    /// Where `@name` pulls a file into the conversation.
    private static let fileTaggers = ["com.microsoft.vscode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
                                      "dev.zed.zed", "com.anthropic.claudefordesktop", "com.openai.codex", "com.cursor"]

    static func isCodingApp(bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        if FormatMode.forApp(bundleID: id) == .terminal { return true }
        return (editors + aiChats).contains { id.hasPrefix($0) }
    }

    /// Terminals count: Claude Code and Codex run there and take `@file` too.
    static func tagsFiles(bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        if FormatMode.forApp(bundleID: id) == .terminal { return true }
        return fileTaggers.contains { id.hasPrefix($0) }
    }

    // MARK: Reading names off the screen

    static let fileExtensions: Set<String> = [
        "swift", "ts", "tsx", "js", "jsx", "mjs", "py", "rb", "go", "rs", "java", "kt", "c", "h", "cc", "cpp", "hpp",
        "m", "mm", "cs", "php", "json", "yml", "yaml", "toml", "md", "html", "css", "scss", "sh", "sql", "vue",
        "svelte", "dart", "ex", "exs", "lua", "xml", "plist", "gradle", "env", "txt",
    ]

    /// Identifiers and file names in `text` worth listening for, most frequent first.
    static func identifiers(in text: String, limit: Int = maxIdentifiers) -> [String] {
        // A name, plus ".ext" only when that's a code file's extension: "self.userName" is two names.
        let exts = fileExtensions.sorted { $0.count > $1.count }.joined(separator: "|")
        guard let regex = try? NSRegularExpression(
            pattern: "[A-Za-z_$][A-Za-z0-9_$\\-]*(?:\\.(?:\(exts))(?![A-Za-z0-9]))?") else { return [] }
        var counts: [String: Int] = [:]
        var order: [String] = []
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: "-_$"))
            guard (3...60).contains(name.count), isWorthMatching(name) else { continue }
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
            if order.count >= 4_000 { break }
        }
        return order.enumerated()
            .sorted { (counts[$0.element]!, -$0.offset) > (counts[$1.element]!, -$1.offset) }
            .prefix(limit)
            .map(\.element)
    }

    /// Two or more words with at least two that carry meaning ("userId", "fetch_all_rows",
    /// "AppState.swift"), so "isOn" or "toString" never turn up inside an ordinary sentence.
    static func isWorthMatching(_ name: String) -> Bool {
        let (stem, ext) = splitFile(name)
        if name.contains("-"), ext == nil { return false }   // "well-known" is prose; kebab names stay as said
        let parts = words(of: stem)
        if ext != nil { return !parts.isEmpty }
        guard parts.count >= 2 else { return false }
        return parts.filter { !functionWords.contains($0) }.count >= 2
    }

    /// "HTTPServer" → [http, server], "userID" → [user, id], "fetch_all_rows" → [fetch, all, rows].
    static func words(of identifier: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(identifier)
        func flush() { if !current.isEmpty { out.append(current.lowercased()); current = "" } }
        for (i, c) in chars.enumerated() {
            if c == "_" || c == "-" || c == "$" || c == "." { flush(); continue }
            if let last = current.last {
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                let startsWord = (c.isUppercase && last.isLowercase)
                    || (c.isUppercase && last.isUppercase && (next?.isLowercase ?? false))
                    || (c.isNumber != last.isNumber)
                if startsWord { flush() }
            }
            current.append(c)
        }
        flush()
        return out
    }

    private static func splitFile(_ name: String) -> (stem: String, ext: String?) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, nil) }
        let ext = String(name[name.index(after: dot)...])
        return fileExtensions.contains(ext.lowercased()) ? (String(name[..<dot]), ext) : (name, nil)
    }

    private static let functionWords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "be", "been", "on", "off", "in", "at", "to", "of", "for", "by", "as",
        "if", "or", "and", "not", "no", "do", "did", "does", "get", "set", "has", "have", "had", "can", "will",
        "should", "up", "out", "all", "new", "it", "its", "this", "that", "with", "from", "into", "each", "so",
        "my", "me", "we", "you", "i", "s",
    ]

    // MARK: Typing them

    /// Swaps spoken runs of words for the on-screen name they spell. Longest names win; a file
    /// name after a spoken "at" becomes an `@` mention where the app takes one.
    static func apply(_ text: String, identifiers: [String], tagFiles: Bool) -> String {
        guard !identifiers.isEmpty, !text.isEmpty,
              let tokenRegex = try? NSRegularExpression(pattern: #"[A-Za-z0-9']+"#) else { return text }
        let ns = text as NSString
        let tokens = tokenRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            (range: $0.range, word: ns.substring(with: $0.range).lowercased())
        }
        guard tokens.count >= 2 else { return text }

        struct Pattern { let name: String; let words: [String]; let isFile: Bool; let needsAt: Bool }
        var patterns: [Pattern] = []
        for name in identifiers {
            let (stem, ext) = splitFile(name)
            let stemWords = words(of: stem)
            if let ext {
                let e = ext.lowercased()
                patterns.append(Pattern(name: name, words: stemWords + ["dot", e], isFile: true, needsAt: false))
                patterns.append(Pattern(name: name, words: stemWords + [e], isFile: true, needsAt: false))
                // Already typed as "AppState.swift": only the @ is missing.
                let typed = stem.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
                if tagFiles, stemWords.count >= 2 {
                    patterns.append(Pattern(name: name, words: [typed, e], isFile: true, needsAt: true))
                }
                // "at app state" means the file when the app takes mentions; elsewhere it's prose.
                if tagFiles, stemWords.count >= 2 {
                    patterns.append(Pattern(name: name, words: stemWords, isFile: true, needsAt: true))
                }
            } else {
                patterns.append(Pattern(name: name, words: stemWords, isFile: false, needsAt: false))
            }
        }
        patterns.sort { $0.words.count > $1.words.count }
        let byFirst = Dictionary(grouping: patterns, by: { $0.words.first ?? "" })

        /// Only spaces, hyphens or a file's dot may sit between the words of one name.
        func joinable(_ a: NSRange, _ b: NSRange) -> Bool {
            let gap = ns.substring(with: NSRange(location: NSMaxRange(a), length: b.location - NSMaxRange(a)))
            return gap.allSatisfy { $0 == " " || $0 == "-" || $0 == "." || $0 == "_" }
        }

        var out = ""
        var cursor = 0          // UTF-16 offset in `text` copied up to
        var i = 0
        while i < tokens.count {
            var matched: (pattern: Pattern, end: Int)?
            for pattern in byFirst[tokens[i].word] ?? [] {
                let n = pattern.words.count
                guard i + n <= tokens.count else { continue }
                var ok = true
                for k in 0..<n where tokens[i + k].word != pattern.words[k] || (k > 0 && !joinable(tokens[i + k - 1].range, tokens[i + k].range)) {
                    ok = false; break
                }
                if ok, pattern.needsAt, !(i > 0 && tokens[i - 1].word == "at") { ok = false }
                if ok { matched = (pattern, i + n - 1); break }
            }
            guard let (pattern, end) = matched else { i += 1; continue }
            var start = tokens[i].range.location
            var replacement = pattern.name
            if pattern.isFile, tagFiles, i > 0, tokens[i - 1].word == "at", joinable(tokens[i - 1].range, tokens[i].range) {
                start = tokens[i - 1].range.location
                replacement = "@" + pattern.name
            }
            out += ns.substring(with: NSRange(location: cursor, length: start - cursor))
            out += replacement
            cursor = NSMaxRange(tokens[end].range)
            i = end + 1
        }
        out += ns.substring(from: cursor)
        return out
    }
}
