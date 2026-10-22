import Foundation

/// A stretch of the transcript that may be the speech model's spelling of one of the user's
/// terms: "cloud" written where Claude was said. Found from the vocabulary's `heardAs` hints.
struct SoundAlike: Sendable, Equatable {
    var heard: String
    var term: String
    /// Byte offsets into the text it was found in.
    var utf8: Range<Int>
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
    static let maxQuestions = 4
    /// How much more likely, in nats, the term's version must be. On the user's own dictations
    /// (see SoundCheckEval) the 0.8B model took every right swap and no wrong one anywhere from 0
    /// to 5; 3 sits in the middle, and was also the only safe value for the 2B it replaced.
    static let margin = 3.0

    /// The same for every check until the vocabulary changes, so the runner caches it.
    static func prefix(terms: [String]) -> String {
        var system = "Transcribed dictation."
        if !terms.isEmpty { system += " The speaker often mentions " + terms.joined(separator: ", ") + "." }
        return "<|im_start|>system\n" + system + "<|im_end|>\n<|im_start|>user\n"
    }

    /// A fixed opening, so the first word of the excerpt is scored too.
    static let lead = "Dictation: "

    /// How much better the term's version reads, in nats. Nil when the model can't run.
    static func advantage(_ runner: LlamaRunner, in text: String, at f: SoundAlike, terms: [String]) async -> Double? {
        let v = SoundAlikes.versions(of: text, around: f)
        guard let scores = try? await runner.compare(prefix: prefix(terms: terms), lead + v.heard, lead + v.term) else { return nil }
        return scores.b - scores.a
    }
}
