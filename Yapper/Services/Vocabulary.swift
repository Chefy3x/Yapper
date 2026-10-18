import Foundation
import Combine

/// One "Whisper heard X, I meant Y" rule. Applied case-insensitively on word boundaries.
struct Replacement: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var heard: String
    var typed: String
    /// Where the rule came from. Nil for rules written before this was tracked: treated as typed in.
    var origin: VocabOrigin? = nil

    /// Two rules are the same rule when they say the same thing; the id is only for lists.
    static func == (lhs: Replacement, rhs: Replacement) -> Bool {
        lhs.heard == rhs.heard && lhs.typed == rhs.typed
    }
}

/// How a word or correction got into the dictionary, so Settings can mark the ones Yapper added.
enum VocabOrigin: String, Codable, Sendable {
    case manual     // typed in Settings
    case learned    // from an edit to something Yapper typed
    case imported   // from Wispr Flow
}

/// The most recent transcript, kept so the user can correct it and teach Yapper the fix.
struct LastTranscript: Codable, Equatable, Sendable {
    var original: String     // what Whisper produced, after the confidence filter
    var delivered: String    // after replacements — what actually got typed
    var at: Date
}

/// Words learned from one edit, kept so the menu can offer to undo them.
struct LearnedBatch: Equatable, Sendable {
    var words: [String]
    var at: Date
    fileprivate var addedTerms: [String]
    /// Corrections this batch wrote, each with the one it replaced (nil when it was new).
    fileprivate var rules: [(new: Replacement, previous: Replacement?)]

    static func == (lhs: LearnedBatch, rhs: LearnedBatch) -> Bool {
        lhs.words == rhs.words && lhs.at == rhs.at
    }
}

/// Persistent vocabulary: terms that bias Whisper's decoding, replacement rules that fix what it
/// still mishears, and the last transcript for the learn-from-correction flow.
/// Stored as JSON next to the audio cache; never leaves the machine.
@MainActor
final class VocabularyStore: ObservableObject {
    @Published var terms: [String] { didSet { save() } }
    @Published var replacements: [Replacement] { didSet { save() } }
    @Published private(set) var lastTranscript: LastTranscript?
    /// How each term arrived, keyed by its lowercased spelling. Terms typed in have no entry.
    @Published private(set) var termOrigins: [String: VocabOrigin] = [:] { didSet { save() } }
    /// The most recent words learned from an edit, until undone or superseded. Not persisted.
    @Published private(set) var recentlyLearned: LearnedBatch?

    private struct File: Codable {
        var terms: [String] = []
        var replacements: [Replacement] = []
        var lastTranscript: LastTranscript?
        var termOrigins: [String: VocabOrigin]?
    }

    private let url: URL

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
        let file = (try? Data(contentsOf: self.url)).flatMap { try? JSONDecoder().decode(File.self, from: $0) } ?? File()
        terms = file.terms
        replacements = file.replacements
        lastTranscript = file.lastTranscript
        termOrigins = file.termOrigins ?? [:]
    }

    static func defaultURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Yapper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("vocabulary.json")
    }

    // MARK: Editing

    func addTerm(_ raw: String, origin: VocabOrigin = .manual) {
        let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !terms.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else { return }
        if origin != .manual { termOrigins[term.lowercased()] = origin }
        terms.append(term)
    }

    func removeTerm(_ term: String) {
        terms.removeAll { $0 == term }
        if !terms.contains(where: { $0.lowercased() == term.lowercased() }) { termOrigins[term.lowercased()] = nil }
    }

    func origin(ofTerm term: String) -> VocabOrigin { termOrigins[term.lowercased()] ?? .manual }

    func addReplacement(heard: String, typed: String, origin: VocabOrigin = .manual) {
        let h = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        // Case-only rules ("yapper" → "Yapper") are the most common kind — proper nouns.
        guard !h.isEmpty, !t.isEmpty, h != t else { return }
        if let idx = replacements.firstIndex(where: { $0.heard.caseInsensitiveCompare(h) == .orderedSame }) {
            replacements[idx].typed = t
            replacements[idx].origin = origin
        } else {
            replacements.append(Replacement(heard: h, typed: t, origin: origin))
        }
    }

    func removeReplacement(_ id: UUID) { replacements.removeAll { $0.id == id } }

    /// Called by the coordinator after every delivery.
    func record(original: String, delivered: String) {
        lastTranscript = LastTranscript(original: original, delivered: delivered, at: Date())
        save()
    }

    /// The user edited the last transcript into what they meant. Every word-run that changed
    /// becomes a replacement rule, and the corrected words join the bias terms — the same
    /// loop Wispr Flow runs implicitly, made explicit because Yapper never sees your edits.
    @discardableResult
    func learn(corrected: String) -> [Replacement] {
        guard let last = lastTranscript else { return [] }
        let learned = TranscriptCorrector.learn(original: last.delivered, corrected: corrected)
        for rule in learned {
            addReplacement(heard: rule.heard, typed: rule.typed, origin: .learned)
            addTerm(rule.typed, origin: .learned)
        }
        lastTranscript = LastTranscript(original: last.original, delivered: corrected, at: last.at)
        save()
        return learned
    }

    /// Words the edit watcher saw the user fix. Each becomes an expected word, and a correction
    /// when it's safe (see `LearnedWord.makesRule`).
    func applyLearned(_ learned: [LearnedWord]) {
        guard !learned.isEmpty else { return }
        var batch = LearnedBatch(words: [], at: Date(), addedTerms: [], rules: [])
        for word in learned {
            if !terms.contains(where: { $0.caseInsensitiveCompare(word.typed) == .orderedSame }) {
                addTerm(word.typed, origin: .learned)
                batch.addedTerms.append(word.typed)
            }
            if word.makesRule {
                let previous = replacements.first { $0.heard.caseInsensitiveCompare(word.heard) == .orderedSame }
                if previous?.typed != word.typed {
                    addReplacement(heard: word.heard, typed: word.typed, origin: .learned)
                    batch.rules.append((Replacement(heard: word.heard, typed: word.typed), previous))
                }
            }
            batch.words.append(word.typed)
        }
        recentlyLearned = batch
    }

    /// Takes back exactly what the last learned batch added, leaving later edits alone.
    func undoLearned() {
        guard let batch = recentlyLearned else { return }
        recentlyLearned = nil
        for term in batch.addedTerms { removeTerm(term) }
        for (rule, previous) in batch.rules {
            guard let idx = replacements.firstIndex(where: { $0.heard.caseInsensitiveCompare(rule.heard) == .orderedSame
                                                             && $0.typed == rule.typed }) else { continue }
            if let previous {
                replacements[idx].typed = previous.typed
                replacements[idx].origin = previous.origin
            } else {
                replacements.remove(at: idx)
            }
        }
    }

    func dismissLearned() { recentlyLearned = nil }

    /// Adds what an import found, skipping anything already here. Returns how many were new.
    @discardableResult
    func merge(terms newTerms: [String], rules newRules: [Replacement]) -> (terms: Int, rules: Int) {
        let termsBefore = terms.count
        let rulesBefore = replacements
        for term in newTerms { addTerm(term, origin: .imported) }
        for rule in newRules where !replacements.contains(where: { $0.heard.caseInsensitiveCompare(rule.heard) == .orderedSame }) {
            addReplacement(heard: rule.heard, typed: rule.typed, origin: .imported)
        }
        return (terms.count - termsBefore, replacements.count - rulesBefore.count)
    }

    private func save() {
        let file = File(terms: terms, replacements: replacements, lastTranscript: lastTranscript,
                        termOrigins: termOrigins.isEmpty ? nil : termOrigins)
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Pure text rules: apply replacements, build the Whisper bias prompt, diff a correction.
enum TranscriptCorrector {

    /// Apply every rule on word boundaries, case-insensitively, longest `heard` first so a
    /// multi-word rule wins over a single word it contains.
    static func apply(_ text: String, replacements: [Replacement]) -> String {
        var out = text
        for rule in replacements.sorted(by: { $0.heard.count > $1.heard.count }) {
            let escaped = NSRegularExpression.escapedPattern(for: rule.heard.trimmingCharacters(in: .whitespaces))
            guard !escaped.isEmpty else { continue }
            let pattern = "(?<![\\p{L}\\p{N}])" + escaped + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(out.startIndex..., in: out)
            let replacement = NSRegularExpression.escapedTemplate(for: rule.typed)
            out = regex.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: replacement)
        }
        return out
    }

    /// Fixes the spelling of words Whisper got nearly right, using the user's terms and the
    /// words on screen. Deliberately narrow, because it runs without asking:
    ///   • two words that together spell a candidate become it ("whisper kit" → "WhisperKit");
    ///   • a word that matches a candidate except for case takes the candidate's case, unless
    ///     the word is an ordinary one ("apple" stays a fruit even with "Apple" on screen);
    ///   • a word the dictionary doesn't know, close in spelling to exactly one candidate,
    ///     becomes it ("Vercell" → "Vercel"). Ordinary words are never respelled.
    static func respell(_ text: String, candidates: [String], isDictionaryWord: (String) -> Bool) -> String {
        let single = candidates.filter { !$0.contains(" ") && $0.count >= 3 }
        guard !single.isEmpty else { return text }
        var byLower: [String: String] = [:]
        for c in single where byLower[c.lowercased()] == nil { byLower[c.lowercased()] = c }

        var tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        func parts(_ token: String) -> (lead: String, core: String, trail: String) {
            let scalars = Array(token)
            var start = 0, end = scalars.count
            while start < end, !(scalars[start].isLetter || scalars[start].isNumber) { start += 1 }
            while end > start, !(scalars[end - 1].isLetter || scalars[end - 1].isNumber) { end -= 1 }
            return (String(scalars[..<start]), String(scalars[start..<end]), String(scalars[end...]))
        }

        // Joined pairs first, so "whisper kit" isn't respelled one half at a time.
        var i = 0
        while i + 1 < tokens.count {
            let a = parts(tokens[i]), b = parts(tokens[i + 1])
            if a.trail.isEmpty, b.lead.isEmpty, !a.core.isEmpty, !b.core.isEmpty,
               let match = byLower[(a.core + b.core).lowercased()] {
                tokens[i] = a.lead + match + b.trail
                tokens.remove(at: i + 1)
            }
            i += 1
        }

        for (index, token) in tokens.enumerated() {
            let p = parts(token)
            guard p.core.count >= 3 else { continue }
            let lower = p.core.lowercased()
            if let match = byLower[lower] {
                if match != p.core, !isDictionaryWord(lower) { tokens[index] = p.lead + match + p.trail }
                continue
            }
            guard p.core.count >= 4, !isDictionaryWord(p.core), !isDictionaryWord(lower) else { continue }
            let close = single.filter { EditLearner.similar(lower, $0.lowercased()) }
            let distinct = Set(close.map { $0.lowercased() })
            if distinct.count == 1, let match = close.first { tokens[index] = p.lead + match + p.trail }
        }
        return tokens.joined(separator: " ")
    }

    /// Whisper's prompt is "text that came before": a comma-separated list of the user's
    /// terms reads as prior context and nudges spelling toward them. Capped well under the
    /// decoder's ~220-token prompt budget; newest terms win when the list is long.
    ///
    /// `screenWords` are read off the focused window for this turn. They come before the user's
    /// own terms, so when the budget runs out it's screen words that drop, never your vocabulary.
    static func prompt(terms: [String], screenWords: [String] = [], maxCharacters: Int = 600) -> String? {
        var seen: Set<String> = []
        var cleaned: [String] = []
        // Walk from the end so a word that is both on screen and in your terms keeps your slot.
        for term in (screenWords + terms).reversed() {
            let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { continue }
            cleaned.insert(t, at: 0)
        }
        guard !cleaned.isEmpty else { return nil }
        var kept: [String] = []
        var length = 0
        for term in cleaned.reversed() {
            let cost = term.count + 2
            if length + cost > maxCharacters { break }
            kept.insert(term, at: 0)
            length += cost
        }
        return kept.joined(separator: ", ") + "."
    }

    /// Word-level diff between what was typed and what the user changed it to. Runs where both
    /// sides changed become `heard → typed` rules. Pure insertions and deletions are ignored —
    /// they're edits of meaning, not of hearing — and runs longer than `maxRunWords` are
    /// treated as rewrites rather than corrections.
    static func learn(original: String, corrected: String, maxRunWords: Int = 4) -> [Replacement] {
        let a = words(original), b = words(corrected)
        let lcs = lcsTable(a.map(\.key), b.map(\.key))
        // Walk the table back to collect aligned pairs, then read off the gaps between them.
        var i = a.count, j = b.count
        var matches: [(Int, Int)] = []
        while i > 0, j > 0 {
            if a[i - 1].key == b[j - 1].key {
                matches.append((i - 1, j - 1)); i -= 1; j -= 1
            } else if lcs[i - 1][j] >= lcs[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        matches.reverse()

        var rules: [Replacement] = []
        var prevA = 0, prevB = 0
        for (ma, mb) in matches + [(a.count, b.count)] {
            let gapA = a[prevA..<ma], gapB = b[prevB..<mb]
            if !gapA.isEmpty, !gapB.isEmpty, gapA.count <= maxRunWords, gapB.count <= maxRunWords {
                rules.append(Replacement(heard: gapA.map(\.core).joined(separator: " "),
                                         typed: gapB.map(\.core).joined(separator: " ")))
            }
            // Aligned on the lowercase key but spelled differently: a capitalisation fix.
            if ma < a.count, mb < b.count, a[ma].core != b[mb].core {
                rules.append(Replacement(heard: a[ma].core, typed: b[mb].core))
            }
            prevA = ma + 1; prevB = mb + 1
        }
        return rules
    }

    // MARK: Word model

    private struct Word {
        let core: String   // token stripped of leading/trailing punctuation, original case
        let key: String    // lowercase core, what the diff compares
    }

    private static func words(_ text: String) -> [Word] {
        text.split(whereSeparator: \.isWhitespace).compactMap { raw in
            let core = String(raw).trimmingCharacters(in: .punctuationCharacters)
            guard !core.isEmpty else { return nil }
            return Word(core: core, key: core.lowercased())
        }
    }

    private static func lcsTable(_ a: [String], _ b: [String]) -> [[Int]] {
        var t = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 1...max(1, a.count) where i <= a.count {
            for j in 1...max(1, b.count) where j <= b.count {
                t[i][j] = a[i - 1] == b[j - 1] ? t[i - 1][j - 1] + 1 : max(t[i - 1][j], t[i][j - 1])
            }
        }
        return t
    }
}
