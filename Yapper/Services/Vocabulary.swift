import Foundation
import Combine

/// One "Whisper heard X, I meant Y" rule. Applied case-insensitively on word boundaries.
struct Replacement: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var heard: String
    var typed: String

    /// Two rules are the same rule when they say the same thing; the id is only for lists.
    static func == (lhs: Replacement, rhs: Replacement) -> Bool {
        lhs.heard == rhs.heard && lhs.typed == rhs.typed
    }
}

/// The most recent transcript, kept so the user can correct it and teach Yapper the fix.
struct LastTranscript: Codable, Equatable, Sendable {
    var original: String     // what Whisper produced, after the confidence filter
    var delivered: String    // after replacements — what actually got typed
    var at: Date
}

/// Persistent vocabulary: terms that bias Whisper's decoding, replacement rules that fix what it
/// still mishears, and the last transcript for the learn-from-correction flow.
/// Stored as JSON next to the audio cache; never leaves the machine.
@MainActor
final class VocabularyStore: ObservableObject {
    @Published var terms: [String] { didSet { save() } }
    @Published var replacements: [Replacement] { didSet { save() } }
    @Published private(set) var lastTranscript: LastTranscript?

    private struct File: Codable {
        var terms: [String] = []
        var replacements: [Replacement] = []
        var lastTranscript: LastTranscript?
    }

    private let url: URL

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
        let file = (try? Data(contentsOf: self.url)).flatMap { try? JSONDecoder().decode(File.self, from: $0) } ?? File()
        terms = file.terms
        replacements = file.replacements
        lastTranscript = file.lastTranscript
    }

    static func defaultURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Yapper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("vocabulary.json")
    }

    // MARK: Editing

    func addTerm(_ raw: String) {
        let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !terms.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else { return }
        terms.append(term)
    }

    func removeTerm(_ term: String) { terms.removeAll { $0 == term } }

    func addReplacement(heard: String, typed: String) {
        let h = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        // Case-only rules ("yapper" → "Yapper") are the most common kind — proper nouns.
        guard !h.isEmpty, !t.isEmpty, h != t else { return }
        if let idx = replacements.firstIndex(where: { $0.heard.caseInsensitiveCompare(h) == .orderedSame }) {
            replacements[idx].typed = t
        } else {
            replacements.append(Replacement(heard: h, typed: t))
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
            addReplacement(heard: rule.heard, typed: rule.typed)
            addTerm(rule.typed)
        }
        lastTranscript = LastTranscript(original: last.original, delivered: corrected, at: last.at)
        save()
        return learned
    }

    private func save() {
        let file = File(terms: terms, replacements: replacements, lastTranscript: lastTranscript)
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

    /// Whisper's prompt is "text that came before": a comma-separated list of the user's
    /// terms reads as prior context and nudges spelling toward them. Capped well under the
    /// decoder's ~220-token prompt budget; newest terms win when the list is long.
    static func prompt(terms: [String], maxCharacters: Int = 600) -> String? {
        let cleaned = terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
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
