import Foundation

/// The finishing touches the speech model leaves off. On a day of the user's dictations, 1 in 9
/// came back with no full stop at the end (mostly the longer ones), 13 had a lowercase "i", and a
/// few started a sentence in lowercase after a full stop. Rules, not the model: instant, and they
/// only add what's missing.
///
/// Runs before the text is fitted to the cursor, which takes the full stop off again when the
/// dictation lands in the middle of a sentence.
enum Punctuation {
    static func finish(_ text: String, mode: FormatMode) -> String {
        guard !text.isEmpty else { return text }
        var out = capitalizeI(text)
        out = capitalizeSentenceStarts(out)
        // A shell line gets nothing tacked on the end: "git status." isn't a command.
        if mode != .terminal { out = closeLastSentence(out) }
        return out
    }

    // MARK: The end

    /// Leading words that don't change what kind of sentence it is: "So can you…" is a question.
    private static let openers: Set<String> = ["so", "and", "but", "okay", "ok", "alright", "yo", "yeah",
                                               "well", "now", "then", "also", "oh", "hey", "like", "or"]
    /// A sentence opening with one of these asks something: "Does that make sense", "Can you…".
    /// Not the "n't" forms: spoken, those mostly open a statement with its subject dropped
    /// ("Doesn't have to be detailed", "Don't worry about it").
    private static let askingVerbs: Set<String> = [
        "is", "are", "was", "were", "am", "do", "does", "did", "can", "could", "would", "should", "will",
        "shall", "have", "has", "had", "may", "might",
    ]
    /// Past this the "sentence" is the speech model running several together, and its first
    /// word says nothing about how it ends.
    static let longestQuestion = 20
    /// A thought cut off on one of these isn't finished; a full stop after it reads wrong.
    private static let danglers: Set<String> = ["a", "an", "the", "but", "and", "or", "so", "to", "of", "with",
                                                "like", "just", "because", "if", "my", "your", "our"]
    private static let questionWords: Set<String> = ["what", "why", "how", "where", "when", "who", "which", "whose"]
    /// "What's", "how's": the question word with its verb already attached.
    private static let askingContractions: Set<String> = ["what's", "how's", "where's", "who's", "why's", "when's",
                                                          "what're", "where're", "who're", "how're"]

    /// A full stop, or a question mark for a question, when the last sentence has neither. Lists
    /// and one-word fragments are left as they are.
    static func closeLastSentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return text }
        if ".!?…:-–—".contains(last) { return text }
        // A list's items go without full stops.
        if trimmed.contains("\n") { return text }
        guard trimmed.split(separator: " ").count >= 2 else { return text }

        var body = trimmed
        // "…make sure that," → "…make sure that."
        while let end = body.last, ",;".contains(end) { body.removeLast() }
        guard let end = body.last, end.isLetter || end.isNumber || "\"'”’)]".contains(end) else { return text }

        let lastWord = body.split(separator: " ").last.map { $0.lowercased() } ?? ""
        if danglers.contains(lastWord) { return text }
        let lastSentence = body.split(whereSeparator: { ".!?".contains($0) }).last.map(String.init) ?? body
        return body + (isQuestion(lastSentence) ? "?" : ".")
    }

    /// Asks something when it opens on a verb that asks ("Does that…", "Can you…") or on a
    /// question word followed by one ("How do we…", "What is…"). "What we're gonna do is…" and
    /// "How it works is…" are statements, so a bare question word isn't enough.
    static func isQuestion(_ sentence: String) -> Bool {
        var words = sentence.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'’"))) }
            .map { $0.replacingOccurrences(of: "’", with: "'") }
            .filter { !$0.isEmpty }
        guard words.count <= longestQuestion else { return false }
        while let first = words.first, openers.contains(first), words.count > 1 { words.removeFirst() }
        guard let first = words.first else { return false }
        if askingVerbs.contains(first) || askingContractions.contains(first) { return true }
        if questionWords.contains(first), words.count > 1 { return askingVerbs.contains(words[1]) }
        return false
    }

    // MARK: Capitals

    private static let pronounI = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}'’.])i(?=(['’](m|ll|ve|d))?(?![\p{L}\p{N}'’]))(?!\.\p{L})"#)

    /// "i think" → "I think", "i'm" → "I'm"; "i.e." stays.
    static func capitalizeI(_ text: String) -> String {
        let ns = NSMutableString(string: text)
        for match in pronounI.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            ns.replaceCharacters(in: NSRange(location: match.range.location, length: 1), with: "I")
        }
        return ns as String
    }

    /// Words a full stop follows without ending the sentence.
    private static let abbreviations: Set<String> = ["e.g", "i.e", "etc", "vs", "dr", "mr", "mrs", "ms", "st",
                                                     "approx", "fig", "inc", "jr", "sr"]
    private static let sentenceStart = try! NSRegularExpression(pattern: #"([.!?])( +)(\p{Ll})"#)

    /// "…Miss Rachel. and I feel…" → "…Miss Rachel. And I feel…". Not after an abbreviation
    /// ("e.g. the"), a single letter ("J. smith" is rare, "t. I" is a mumble), or a file name.
    static func capitalizeSentenceStarts(_ text: String) -> String {
        let ns = NSMutableString(string: text)
        for match in sentenceStart.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let mark = ns.substring(with: match.range(at: 1))
            if mark == "." {
                let before = ns.substring(to: match.range.location)
                let word = before.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
                let bare = word.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted)
                if word.count <= 1 || abbreviations.contains(bare) || word.contains(".") || word.contains("/") { continue }
            }
            let letter = match.range(at: 3)
            ns.replaceCharacters(in: letter, with: ns.substring(with: letter).uppercased())
        }
        return ns as String
    }
}
