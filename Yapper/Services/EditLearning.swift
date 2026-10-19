import AppKit

/// One word the user fixed by hand after Yapper typed it.
struct LearnedWord: Equatable, Sendable {
    var heard: String
    var typed: String
    /// Also add a `heard → typed` correction. Only when `heard` isn't an ordinary word: learning
    /// "cloud → Claude" as a rule would turn every cloud you ever mention into Claude, so a
    /// dictionary word only teaches Whisper the new spelling to expect.
    var makesRule: Bool
}

/// Works out which words the user corrected in a pasted transcript, the way Wispr Flow does: watch
/// the field, align the words, and keep only isolated one-word swaps that look like a mishearing.
/// A rewrite, a deleted clause, or a grammar fix ("their" → "there") teaches nothing.
///
/// Wispr Flow asks a server-side classifier whether each swap is worth keeping. Yapper uses the
/// system dictionary instead: a swap is kept when the new word is one Whisper can't be expected
/// to know (not in the dictionary, or a capitalised name), and spelled close to what it heard.
enum EditLearner {
    /// More fixes than this in one dictation is an edit of meaning, not of hearing.
    static let maxPerDictation = 4

    /// `delivered` is what Yapper typed. `baseline` is the field's text right after the paste and
    /// `edited` its text once the user was done, both whole-field.
    static func learn(delivered: String, baseline: String, edited: String,
                      isDictionaryWord: (String) -> Bool) -> [LearnedWord] {
        guard edited != baseline else { return [] }
        let region = editedRegion(delivered: delivered, baseline: baseline, edited: edited)
        let a = words(delivered), b = words(region)
        guard !a.isEmpty, !b.isEmpty else { return [] }

        let matches = align(a.map(\.key), b.map(\.key))
        // Most of the dictation must survive, or this was a rewrite.
        guard Double(matches.count) >= Double(a.count) * 0.6 else { return [] }

        var found: [LearnedWord] = []
        var prevA = 0, prevB = 0
        for (ma, mb) in matches + [(a.count, b.count)] {
            let gapA = a[prevA..<ma], gapB = b[prevB..<mb]
            if gapA.count == 1, gapB.count == 1, let heard = gapA.first, let typed = gapB.first,
               let word = swap(heard: heard, typed: typed, sentenceStart: isSentenceStart(a, prevA),
                               isDictionaryWord: isDictionaryWord) {
                found.append(word)
            } else if !gapA.isEmpty, !gapB.isEmpty, gapA.count > 1 || gapB.count > 1 {
                // A multi-word change sits inside the dictation: the user reworded it. Anything
                // learned from the same edit is suspect.
                return []
            }
            // Same word, different case: "yapper" → "Yapper".
            if ma < a.count, mb < b.count, a[ma].core != b[mb].core,
               let word = recase(heard: a[ma], typed: b[mb], sentenceStart: isSentenceStart(a, ma)) {
                found.append(word)
            }
            prevA = ma + 1; prevB = mb + 1
        }
        guard found.count <= maxPerDictation else { return [] }
        return found
    }

    // MARK: Rules

    private static func swap(heard: Word, typed: Word, sentenceStart: Bool,
                             isDictionaryWord: (String) -> Bool) -> LearnedWord? {
        guard heard.key != typed.key, typed.core.count >= 2,
              typed.core.contains(where: \.isLetter) else { return nil }
        let typedIsName = typed.core.first!.isUppercase && !sentenceStart
        let typedIsUnknown = !isDictionaryWord(typed.core) && !isDictionaryWord(typed.key)
        guard typedIsName || typedIsUnknown else { return nil }   // "their" → "there" is grammar
        guard similar(heard.key, typed.key) else { return nil }   // a different word, not a mishearing
        let heardIsOrdinary = isDictionaryWord(heard.key)
        return LearnedWord(heard: heard.core, typed: typed.core, makesRule: !heardIsOrdinary)
    }

    private static func recase(heard: Word, typed: Word, sentenceStart: Bool) -> LearnedWord? {
        // Capitalising the first word of a sentence is grammar, and lowering a name is a choice.
        guard !sentenceStart, typed.core.first!.isUppercase || typed.core.dropFirst().contains(where: \.isUppercase)
        else { return nil }
        return LearnedWord(heard: heard.core, typed: typed.core, makesRule: true)
    }

    /// Close enough in spelling to be the same sound heard wrong. Generous, because Whisper's
    /// guesses at names are phonetic ("Zefira" for "Zephyra"), but not so loose that any two
    /// words of similar length pass.
    static func similar(_ a: String, _ b: String) -> Bool {
        let distance = levenshtein(Array(a), Array(b))
        let longest = max(a.count, b.count)
        if a.first == b.first { return distance <= max(2, longest / 2) }
        return distance <= max(1, longest / 3)
    }

    private static func isSentenceStart(_ words: [Word], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        guard let last = words[index - 1].raw.last else { return false }
        return ".!?".contains(last)
    }

    // MARK: Locating the dictation in the field

    /// The part of the edited field that corresponds to the pasted transcript: the field minus
    /// whatever was before and after the paste, when those survived the edit.
    static func editedRegion(delivered: String, baseline: String, edited: String) -> String {
        guard let range = baseline.range(of: delivered, options: .backwards) else { return edited }
        let prefix = String(baseline[..<range.lowerBound])
        let suffix = String(baseline[range.upperBound...])
        var region = Substring(edited)
        if !prefix.isEmpty, region.hasPrefix(prefix) { region = region.dropFirst(prefix.count) }
        if !suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, region.hasSuffix(suffix) {
            region = region.dropLast(suffix.count)
        }
        return String(region)
    }

    // MARK: Word model

    struct Word {
        let raw: String
        let core: String   // stripped of surrounding punctuation, original case
        let key: String    // lowercase core
    }

    static func words(_ text: String) -> [Word] {
        text.split(whereSeparator: \.isWhitespace).compactMap { raw in
            let core = String(raw).trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            guard !core.isEmpty else { return nil }
            return Word(raw: String(raw), core: core, key: core.lowercased())
        }
    }

    /// Longest-common-subsequence alignment, as index pairs in order.
    private static func align(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        var t = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                t[i][j] = a[i] == b[j] ? t[i + 1][j + 1] + 1 : max(t[i + 1][j], t[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { pairs.append((i, j)); i += 1; j += 1 }
            else if t[i + 1][j] >= t[i][j + 1] { i += 1 }
            else { j += 1 }
        }
        return pairs
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}

/// Watches the field a transcript was pasted into for a minute, then learns from what the user
/// changed. Polls instead of subscribing to AX notifications: Electron apps fire value changes
/// inconsistently, and one read every 1.5 s costs nothing.
@MainActor
final class EditWatcher {
    static let watchFor: TimeInterval = 60
    static let pollEvery: TimeInterval = 1.5

    /// Words learned from a finished watch, already filtered by `EditLearner`.
    var onLearned: (([LearnedWord]) -> Void)?

    private var task: Task<Void, Never>?
    private var current: (delivered: String, baseline: String, latest: String)?

    func watch(_ receipt: DeliveryReceipt, delivered: String) {
        finish()
        guard let field = receipt.field, !field.isSecure, let baseline = receipt.valueAfter,
              baseline.contains(delivered) else { return }
        current = (delivered, baseline, baseline)
        task = Task { [weak self] in
            let started = Date()
            while Date().timeIntervalSince(started) < Self.watchFor {
                try? await Task.sleep(for: .seconds(Self.pollEvery))
                if Task.isCancelled { return }
                let snapshot = await Self.read(field)
                guard let self, !Task.isCancelled else { return }
                guard let value = snapshot else { break }   // focus moved to another app, or the field went away
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }   // sent
                self.current?.latest = value
            }
            self?.finish()
        }
    }

    /// A new dictation is starting, or the watch ran out: learn from the last text seen.
    func finish() {
        task?.cancel()
        task = nil
        guard let watched = current else { return }
        current = nil
        let learned = EditLearner.learn(delivered: watched.delivered, baseline: watched.baseline,
                                        edited: watched.latest, isDictionaryWord: { WordKnowledge.isDictionaryWord($0) })
        guard !learned.isEmpty else { return }
        Log.voice.info("Learned \(learned.count, privacy: .public) word(s) from an edit")
        onLearned?(learned)
    }

    @AXWorker
    private static func read(_ field: FocusedField) -> String? {
        // Only while the user is still in that app; text read from a backgrounded field may
        // be a different conversation by now.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == field.pid else { return nil }
        return field.value
    }
}
