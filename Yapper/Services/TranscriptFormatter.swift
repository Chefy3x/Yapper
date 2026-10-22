import Foundation

/// How a transcript should be laid out for the app it's going into.
enum FormatMode: String, Sendable, CaseIterable {
    /// Chat composers: Claude, ChatGPT, Slack, Messages. Lists as numbered lines.
    case chat
    /// Mail: lists as numbered lines, paragraphs kept.
    case email
    /// Notes and documents: lists as "- " lines, the way Markdown notes write them.
    case document
    /// Terminals: one line, always. A pasted newline in a shell runs whatever came before it,
    /// and Yapper never presses Return, so a list stays inline here.
    case terminal

    static func forApp(bundleID: String?) -> FormatMode {
        guard let id = bundleID?.lowercased() else { return .chat }
        if terminals.contains(where: { id.hasPrefix($0) }) { return .terminal }
        if mail.contains(where: { id.hasPrefix($0) }) { return .email }
        if documents.contains(where: { id.hasPrefix($0) }) { return .document }
        return .chat
    }

    private static let terminals = ["com.apple.terminal", "com.googlecode.iterm2", "dev.warp", "com.mitchellh.ghostty",
                                    "net.kovidgoyal.kitty", "io.alacritty", "co.zeit.hyper", "com.github.wez.wezterm"]
    private static let mail = ["com.apple.mail", "com.microsoft.outlook", "com.superhuman", "com.readdle.smartemail",
                               "com.mimestream", "it.bloop.airmail"]
    private static let documents = ["com.apple.notes", "md.obsidian", "com.apple.iwork.pages", "com.microsoft.word",
                                    "notion.id", "net.shinyfrog.bear", "com.apple.textedit", "com.craft",
                                    "com.agiletortoise.drafts", "com.ulyssesapp"]

    var allowsLineBreaks: Bool { self != .terminal }

    var listStyle: String {
        switch self {
        case .chat, .email: "put each item on its own line, numbered \"1.\", \"2.\", \"3.\""
        case .document: "put each item on its own line starting with \"- \""
        case .terminal: "keep everything on one line and write the items inline, separated by commas"
        }
    }

    func listLines(_ items: [String]) -> String {
        switch self {
        case .chat, .email: items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        case .document: items.map { "- \($0)" }.joined(separator: "\n")
        case .terminal: items.joined(separator: ", ")
        }
    }
}

/// When a transcript is worth sending through the model at all. Most dictations aren't, and
/// skipping them costs nothing: no load, no lag.
enum FormatCues {
    private static let correction = try! NSRegularExpression(pattern:
        #"\b(no,? wait|wait,? no|no,? actually|i mean|i meant|scratch that|strike that|or rather|let me rephrase|correction|actually,? (make|change) (that|it))\b"#,
        options: [.caseInsensitive])
    private static let list = try! NSRegularExpression(pattern:
        #"\b(first(ly)?\b.{1,400}\bsecond(ly)?|number one|step one|bullet points?|the following (things|items|points|steps)|(a couple of|a few|three|four|five|six|several) (things|items|points|steps|reasons|options))\b"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])

    /// "I mean" opening a sentence ("…leaving. I mean, I'm already…") is how people talk, not a
    /// correction; on the user's dictations it sent text to the model for 1.8 s and changed
    /// nothing. Mid-sentence it still counts: "word, I mean letter by letter".
    static func hasCorrection(_ text: String) -> Bool {
        correction.matches(in: text, range: NSRange(text.startIndex..., in: text)).contains { match in
            guard let range = Range(match.range, in: text) else { return false }
            guard text[range].lowercased() == "i mean" else { return true }
            let before = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            return !(before.isEmpty || ".!?".contains(before.last!))
        }
    }

    /// The text after the last correction phrase, or nil when there is none.
    static func afterLastCorrection(_ text: String) -> String? {
        let matches = correction.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let last = matches.last, let range = Range(last.range, in: text) else { return nil }
        return String(text[range.upperBound...])
    }
    static func hasList(_ text: String) -> Bool { matches(list, text) }

    private static let filler = try! NSRegularExpression(pattern:
        #"\b(like|so|right|yeah|okay|you know|i mean|basically|kind of|sort of|literally|honestly)\b"#,
        options: [.caseInsensitive])

    static func hasFiller(_ text: String) -> Bool { matches(filler, text) }

    /// `cleanup` also sends dictations that only have filler in them, for the model to tidy.
    static func needsFormatting(_ text: String, cleanup: Bool = false) -> Bool {
        guard text.split(whereSeparator: \.isWhitespace).count >= 4 else { return false }
        return hasCorrection(text) || hasList(text) || (cleanup && hasFiller(text))
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

/// The instructions and examples the small model sees. One narrow job, stated as rules, then
/// shown: a small model follows examples far better than prose.
enum FormatPrompt {
    static let system = """
    You tidy up dictated text. Return the same text with only these changes:
    1. Self-corrections. When the speaker corrects themselves ("no wait", "I mean", "scratch that", "or rather"), keep only what they settled on. Remove the words they abandoned and the correction phrase itself.
    2. Lists. When the speaker lists items ("first… second…", "number one…", "three things…"), %LIST%. Drop the spoken counting words ("first", "second", "and third") that the layout replaces.
    %CLEANUP%Everything else stays exactly as spoken: same words, same order, same spelling. Never add a word. Never rephrase, summarise, answer, explain, or translate. If nothing applies, return the text unchanged. Reply with the text only.
    """

    static let cleanupRule = """
    3. Filler and false starts. Remove words that carry no meaning: um and uh, filler "like", "you know", "I mean", "kind of", "basically", and a "right?" tacked onto a statement. Leave a "so", "and" or "yeah" that opens a sentence. Remove false starts, where the speaker begins a phrase and then says it again. Keep every word that adds meaning: "I like it" keeps its "like".

    """

    private struct Example: Sendable { let input: String; let output: @Sendable (FormatMode) -> String }

    private static let cleanupExamples: [Example] = [
        Example(input: "So like I was thinking we could, we could maybe move the meeting to Friday, right?") { _ in
            "So I was thinking we could maybe move the meeting to Friday."
        },
        Example(input: "And then it's like the whole page just, it just breaks when you scroll.") { _ in
            "And then the whole page just breaks when you scroll."
        },
        Example(input: "Yeah so basically the build is green now.") { _ in "Yeah so the build is green now." },
        Example(input: "I like how the new design looks.") { _ in "I like how the new design looks." },
    ]

    private static let examples: [Example] = [
        Example(input: "Let's meet at 3, no wait, 4 tomorrow.") { _ in "Let's meet at 4 tomorrow." },
        Example(input: "Send the draft to Mike, I mean Sarah, by Friday.") { _ in "Send the draft to Sarah by Friday." },
        Example(input: "For the trip I need three things. First, my passport. Second, the charger. And third, a warm jacket.") { mode in
            mode == .terminal
                ? "For the trip I need three things: my passport, the charger, a warm jacket."
                : "For the trip I need three things:\n" + mode.listLines(["My passport", "The charger", "A warm jacket"])
        },
        Example(input: "I actually think the second option is better, so let's go with that.") { _ in
            "I actually think the second option is better, so let's go with that."
        },
        Example(input: "Can you check the logs and, scratch that, can you restart the server?") { _ in
            "Can you restart the server?"
        },
        Example(input: "Call the dentist on Monday, I mean, call the dentist on Tuesday.") { _ in
            "Call the dentist on Tuesday."
        },
        Example(input: "Put the meeting in the big room and, actually, make that the small room.") { _ in
            "Put the meeting in the small room."
        },
        Example(input: "So the plan is, number one, we fix the bug, and number two, we tell the team.") { mode in
            mode == .terminal
                ? "So the plan is: we fix the bug, we tell the team."
                : "So the plan is:\n" + mode.listLines(["We fix the bug", "We tell the team"])
        },
    ]

    /// Qwen's ChatML, with the thinking block closed up front: a small model reasoning aloud is
    /// slower and no better at this.
    static func build(text: String, mode: FormatMode, cleanup: Bool = false) -> String {
        prefix(mode: mode, cleanup: cleanup) + suffix(text: text)
    }

    /// Instructions and examples: the same for every request in a mode, so the runner caches it.
    static func prefix(mode: FormatMode, cleanup: Bool = false) -> String {
        let rules = system
            .replacingOccurrences(of: "%LIST%", with: mode.listStyle)
            .replacingOccurrences(of: "%CLEANUP%", with: cleanup ? cleanupRule : "")
        var out = "<|im_start|>system\n" + rules + "<|im_end|>\n"
        for example in examples + (cleanup ? cleanupExamples : []) {
            out += turn(user: example.input, assistant: example.output(mode))
        }
        return out
    }

    static func suffix(text: String) -> String {
        "<|im_start|>user\n\(text)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }

    private static func turn(user: String, assistant: String) -> String {
        "<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n\(assistant)<|im_end|>\n"
    }

    /// The model's reply with any stray markup trimmed.
    static func clean(_ raw: String) -> String {
        var s = raw
        if let end = s.range(of: "</think>") { s = String(s[end.upperBound...]) }
        s = s.replacingOccurrences(of: "<|im_end|>", with: "")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Decides whether the model's version may replace what Whisper heard. The model is small and
/// runs unattended, so anything it does beyond deleting words and laying out a list is refused,
/// and the raw transcript goes out instead. A wrong format is a nuisance; a changed meaning in
/// a message you didn't reread is a real problem.
enum FormatGuard {
    enum Verdict: Equatable, Sendable {
        case accept(String)
        case unchanged
        case reject(String)   // why, for the log
    }

    static func check(input: String, output: String, mode: FormatMode, cleanup: Bool = false) -> Verdict {
        let out = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return .reject("empty") }
        if out == input.trimmingCharacters(in: .whitespacesAndNewlines) { return .unchanged }
        if !mode.allowsLineBreaks, out.contains("\n") { return .reject("line break in a one-line app") }
        if out.contains("<|") || out.lowercased().hasPrefix("here") { return .reject("markup or preamble") }
        guard out.count <= input.count + input.count / 4 + 20 else { return .reject("longer than the dictation") }

        let a = words(input), b = words(stripListMarkers(out))
        guard !b.isEmpty else { return .reject("no words") }
        let common = lcs(a, b)
        let added = b.count - common
        let removed = a.count - common
        if added > 0 { return .reject("added or reordered \(added) word(s)") }
        // Self-corrections remove the abandoned words; a list removes its counting words. More
        // than that and the model has started summarising.
        if let tail = FormatCues.afterLastCorrection(input) {
            // Whatever follows the last "I mean" is what the speaker settled on. Losing any of
            // it means the model kept the wrong version ("tell Jordan" over "tell Priya").
            let settled = words(tail)
            if lcs(settled, b) < settled.count { return .reject("lost the corrected wording") }
            if removed > max(8, a.count * 45 / 100) { return .reject("removed \(removed) of \(a.count) words") }
        } else if cleanup, removed > 0 {
            // Filler and false starts: the words that may go are fillers, small connecting
            // words, and words that still appear in the result (the half of a restart that was
            // said again). A dropped noun or number that is gone entirely is content.
            if removed > max(4, a.count * 30 / 100) { return .reject("removed \(removed) of \(a.count) words") }
            let kept = Set(b)
            let gone = multisetDifference(a, b)
            if let stray = gone.first(where: { !kept.contains($0) && !cleanupRemovable.contains($0) }) {
                return .reject("dropped \"\(stray)\"")
            }
        } else if removed > 0 {
            // Without a correction the only words that may go are the counting ones.
            let gone = multisetDifference(a, b)
            if let stray = gone.first(where: { !countingWords.contains($0) && !fillers.contains($0) }) {
                return .reject("dropped \"\(stray)\"")
            }
        }
        if words(out) == a, !out.contains("\n") { return .unchanged }   // punctuation-only fiddling
        return .accept(out)
    }

    static let countingWords: Set<String> = [
        "first", "firstly", "second", "secondly", "third", "thirdly", "fourth", "fifth", "sixth", "seventh",
        "and", "then", "next", "finally", "lastly", "number", "one", "two", "three", "four", "five", "six",
        "seven", "step", "also", "bullet", "point", "points",
    ]

    static let fillers: Set<String> = ["okay", "ok", "um", "uh", "er", "erm"]

    /// What filler cleanup may delete outright: the fillers themselves and the small words a
    /// false start is made of.
    static let cleanupRemovable: Set<String> = fillers.union(countingWords).union([
        "like", "so", "right", "yeah", "you", "know", "i", "mean", "basically", "kind", "sort", "of", "just",
        "literally", "honestly", "actually", "really", "well", "oh", "alright", "anyway",
        "the", "a", "an", "it", "it's", "that", "that's", "this", "is", "was", "be", "we", "we're", "i'm", "i've",
        "you're", "they", "he", "she", "to", "in", "on", "at", "for", "with", "but", "or", "if", "do", "did",
        "have", "has", "can", "could", "would", "will", "gonna", "going", "want", "wanna", "there", "here",
        "what", "how", "my", "your", "our", "me", "us", "them", "are", "were", "been", "get", "got",
    ])

    private static let marker = try! NSRegularExpression(pattern: #"(?m)^\s*(?:\d+[.)]|[-•*])\s+"#)

    static func stripListMarkers(_ text: String) -> String {
        marker.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters.union(.symbols)) }
            .filter { !$0.isEmpty }
    }

    private static func multisetDifference(_ a: [String], _ b: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for w in b { counts[w, default: 0] += 1 }
        var out: [String] = []
        for w in a {
            if let c = counts[w], c > 0 { counts[w] = c - 1 } else { out.append(w) }
        }
        return out
    }

    private static func lcs(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var prev = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            var cur = [Int](repeating: 0, count: b.count + 1)
            for j in 1...b.count {
                cur[j] = a[i - 1] == b[j - 1] ? prev[j - 1] + 1 : max(prev[j], cur[j - 1])
            }
            prev = cur
        }
        return prev[b.count]
    }
}
