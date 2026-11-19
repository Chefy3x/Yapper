import Foundation

/// A stretch of the transcript that may be the speech model's spelling of one of the user's
/// terms: "cloud" written where Claude was said. Found from the vocabulary's `heardAs` hints,
/// or by sound against the user's terms and the names on screen.
struct SoundAlike: Sendable, Equatable {
    var heard: String
    var term: String
    /// Byte offsets into the text it was found in.
    var utf8: Range<Int>
    /// From a `heardAs` hint the user's vocabulary vouches for. Spots found only by sound need a
    /// clearer win in the context check.
    var hinted = true
}

/// Pure text helpers for sound-alikes.
enum SoundAlikes {
    /// Every place a `heardAs` entry appears in `text`, on word boundaries and in any case.
    /// Longer entries win where two overlap ("claw code" over "claw"). `heardAs` is keyed by the
    /// lowercased term; entries for words no longer in `terms` are ignored.
    static func spots(in text: String, heardAs: [String: [String]], terms: [String]) -> [SoundAlike] {
        var candidates: [SoundAlike] = []
        for term in terms {
            for heard in heardAs[term.lowercased()] ?? [] where heard.lowercased() != term.lowercased() {
                let escaped = NSRegularExpression.escapedPattern(for: heard)
                guard let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])" + escaped + "(?![\\p{L}\\p{N}])",
                                                           options: [.caseInsensitive]) else { continue }
                for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    guard let r = Range(match.range, in: text) else { continue }
                    let start = text.utf8.distance(from: text.startIndex, to: r.lowerBound)
                    let length = text[r].utf8.count
                    candidates.append(SoundAlike(heard: String(text[r]), term: term, utf8: start..<(start + length)))
                }
            }
        }
        var taken: [SoundAlike] = []
        for c in candidates.sorted(by: { $0.utf8.count > $1.utf8.count }) where !taken.contains(where: { $0.utf8.overlaps(c.utf8) }) {
            taken.append(c)
        }
        return taken.sorted { $0.utf8.lowerBound < $1.utf8.lowerBound }
    }

    // MARK: Found by sound

    /// Words so common that a name sounding like one is far likelier to be that word: checking
    /// "called" against Claude on every dictation would only cost time.
    private static let common: Set<String> = [
        "the", "and", "that", "this", "with", "they", "them", "then", "than", "there", "their", "what", "when",
        "where", "which", "have", "just", "like", "will", "would", "could", "should", "about", "from", "your",
        "into", "some", "been", "were", "here", "know", "want", "going", "gonna", "make", "made", "take", "said",
        "called", "call", "cold", "good", "great", "right", "really", "also", "only", "over", "back", "think",
        "thing", "things", "look", "need", "come", "came", "every", "still", "even", "much", "more", "most",
        "other", "these", "those", "doing", "being", "after", "before", "because", "cause", "yeah", "okay",
    ]

    /// A rough key for how a word sounds: consonants only, voiced and unvoiced pairs merged, silent
    /// and doubled letters dropped. Claude, cloud and clawed all come out KLT; Qwen and Quinn KN.
    static func soundKey(_ word: String) -> String {
        var s = Array(word.lowercased().filter { $0.isLetter && $0.isASCII })
        guard !s.isEmpty else { return "" }
        func starts(_ p: String) -> Bool { s.starts(with: Array(p)) }
        if starts("kn") || starts("gn") || starts("pn") || starts("wr") { s.removeFirst() }
        var out: [Character] = []
        var i = 0
        while i < s.count {
            let c = s[i], next: Character? = i + 1 < s.count ? s[i + 1] : nil
            var k: Character?
            switch c {
            case "a", "e", "i", "o", "u", "y", "w", "h":
                k = nil
            case "c":
                if next == "k" { k = nil }
                else if next == "h" { k = "X"; i += 1 }
                else { k = ["e", "i", "y"].contains(next) ? "S" : "K" }
            case "p": if next == "h" { k = "F"; i += 1 } else { k = "P" }
            case "g": if next == "h" { k = nil; i += 1 } else { k = "K" }
            case "s": if next == "h" { k = "X"; i += 1 } else { k = "S" }
            case "t": if next == "h" { k = "0"; i += 1 } else { k = "T" }
            case "b": k = "P"
            case "d": k = "T"
            case "q", "k": k = "K"
            case "v": k = "F"
            case "z": k = "S"
            case "j": k = "J"
            case "x": out.append("K"); k = "S"
            default: k = Character(c.uppercased())
            }
            if let k, out.last != k { out.append(k) }
            i += 1
        }
        return String(out)
    }

    /// Single-word names worth listening for: the user's terms and the screen's names, minus
    /// ordinary words and anything too short to compare by sound.
    static func names(_ words: [String], isDictionaryWord: (String) -> Bool) -> [String] {
        var seen: Set<String> = [], out: [String] = []
        for w in words where !w.contains(" ") && w.count >= 3 && w.allSatisfy(\.isLetter) {
            let lower = w.lowercased()
            guard !isDictionaryWord(lower), soundKey(w).count >= 2, seen.insert(lower).inserted else { continue }
            out.append(w)
        }
        return out
    }

    /// Words (or two words run together) that sound like one of `names` without being it:
    /// "cloud" for Claude, "quinn" for Qwen, "groc" for Grok. Same sound key, or one consonant
    /// off for longer names ("parakey" for Parakeet). A word that matches two names is skipped.
    static func phoneticSpots(in text: String, names: [String]) -> [SoundAlike] {
        guard !names.isEmpty, let regex = try? NSRegularExpression(pattern: #"[A-Za-z][A-Za-z']*"#) else { return [] }
        let keyed = names.map { (name: $0, lower: $0.lowercased(), key: soundKey($0)) }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        func utf8(_ r: NSRange) -> Range<Int> {
            let range = Range(r, in: text)!
            let start = text.utf8.distance(from: text.startIndex, to: range.lowerBound)
            return start..<(start + text[range].utf8.count)
        }
        /// `pair`: two words run together, which must sound exactly like the name (and may be
        /// spelled like it: "whisper kit" is WhisperKit).
        func match(_ heard: String, pair: Bool = false) -> String? {
            let lower = heard.lowercased()
            guard lower.count >= 3, !common.contains(lower) else { return nil }
            let key = soundKey(heard)
            guard key.count >= 2 else { return nil }
            let hits = keyed.filter { n in
                if pair { return n.key == key }
                // Sounding alike isn't enough on its own ("can" and Qwen share KN): the spelling
                // has to be close too, the way "cloud" is to Claude and "groc" to Grok.
                guard n.lower != lower, key.count >= 3, EditLearner.similar(lower, n.lower) else { return false }
                if n.key == key { return true }
                return n.key.count >= 4 && key.first == n.key.first
                    && EditLearner.levenshtein(Array(key), Array(n.key)) <= 1
            }
            return Set(hits.map(\.lower)).count == 1 ? hits[0].name : nil
        }
        var found: [SoundAlike] = []
        for (i, m) in matches.enumerated() {
            let heard = ns.substring(with: m.range)
            // Two words run together first: "whisper kit", "cloud flare".
            if i + 1 < matches.count {
                let n = matches[i + 1]
                let gap = ns.substring(with: NSRange(location: m.range.upperBound, length: n.range.location - m.range.upperBound))
                if gap == " " {
                    let pair = heard + ns.substring(with: n.range)
                    if soundKey(pair).count >= 4, let name = match(pair, pair: true) {
                        let r = NSRange(location: m.range.location, length: n.range.upperBound - m.range.location)
                        found.append(SoundAlike(heard: ns.substring(with: r), term: name, utf8: utf8(r), hinted: false))
                        continue
                    }
                }
            }
            if let name = match(heard) {
                found.append(SoundAlike(heard: heard, term: name, utf8: utf8(m.range), hinted: false))
            }
        }
        var taken: [SoundAlike] = []
        for f in found where !taken.contains(where: { $0.utf8.overlaps(f.utf8) }) { taken.append(f) }
        return taken
    }

    /// Writes each term over the words it replaces. Overlapping spots after the first are skipped.
    static func apply(_ found: [SoundAlike], to text: String) -> String {
        var bytes = Array(text.utf8)
        var taken: [SoundAlike] = []
        for f in found where f.utf8.upperBound <= bytes.count && !taken.contains(where: { $0.utf8.overlaps(f.utf8) }) {
            taken.append(f)
        }
        for f in taken.sorted(by: { $0.utf8.lowerBound > $1.utf8.lowerBound }) {
            bytes.replaceSubrange(f.utf8, with: Array(f.term.utf8))
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The words around a spot, as heard and with the term in its place: a sentence's worth
    /// rather than a two-minute dictation.
    static func versions(of text: String, around f: SoundAlike, words limit: Int = 24) -> (heard: String, term: String) {
        let bytes = Array(text.utf8)
        guard f.utf8.upperBound <= bytes.count else { return (text, text) }
        let before = String(decoding: bytes[..<f.utf8.lowerBound], as: UTF8.self)
        let after = String(decoding: bytes[f.utf8.upperBound...], as: UTF8.self)
        // One more piece than words: the space beside the spot splits off an empty one.
        let lead = before.split(separator: " ", omittingEmptySubsequences: false).suffix(limit + 1).joined(separator: " ")
        let tail = after.split(separator: " ", omittingEmptySubsequences: false).prefix(limit + 1).joined(separator: " ")
        return (lead + f.heard + tail, lead + f.term + tail)
    }
}

/// The context check: which reads more like what was meant, the sentence as heard or with the
/// user's term in it? Qwen scores both versions (how likely each word is, given the words before
/// it) instead of being asked a question, which a small model answers unreliably. No text is
/// generated, so it's quick.
enum ContextCheck {
    /// Spots checked per dictation; past it, the rest keep what was heard.
    static let maxQuestions = 5
    /// How much more likely, in nats, the term's version must be. On the user's own dictations
    /// (see SoundCheckEval) the 0.8B model took every right swap and no wrong one anywhere from 0
    /// to 5; 3 sits in the middle, and was also the only safe value for the 2B it replaced.
    static let margin = 3.0
    /// For spots found only by sound, with no `heardAs` hint behind them: a wider win, so an
    /// ordinary word that happens to sound like a name stays unless the sentence clearly wants the name.
    static let unhintedMargin = 4.5
    /// Names from the screen given to the model, so "the cloud app" reads as Claude when
    /// Claude is what's open.
    static let maxScreenNames = 40

    /// The same for every check until the vocabulary changes, so the runner caches it.
    static func prefix(terms: [String], screen: [String] = []) -> String {
        var system = "Transcribed dictation."
        if !terms.isEmpty { system += " The speaker often mentions " + terms.joined(separator: ", ") + "." }
        let shown = screen.prefix(maxScreenNames)
        if !shown.isEmpty { system += " On the speaker's screen right now: " + shown.joined(separator: ", ") + "." }
        return "<|im_start|>system\n" + system + "<|im_end|>\n<|im_start|>user\n"
    }

    /// A fixed opening, so the first word of the excerpt is scored too.
    static let lead = "Dictation: "

    /// How much better the term's version reads, in nats. Nil when the model can't run.
    static func advantage(_ runner: LlamaRunner, in text: String, at f: SoundAlike, terms: [String],
                          screen: [String] = []) async -> Double? {
        let v = SoundAlikes.versions(of: text, around: f)
        guard let scores = try? await runner.compare(prefix: prefix(terms: terms, screen: screen), lead + v.heard, lead + v.term)
        else { return nil }
        return scores.b - scores.a
    }
}
