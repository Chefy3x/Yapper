import Foundation

/// Takes the stumbles out of a transcript with plain rules: "um" and "uh", stutters ("w- we"),
/// a word or short phrase said twice ("I think I think"), and the few filler patterns that are
/// almost never meant. Instant, so it runs on every dictation at any length.
///
/// Every rule here was checked against 7,000 real dictations and the cleanup Wispr Flow did on
/// them: each one removes words Wispr Flow also removed at least 85% of the time. Fillers that
/// depend on meaning ("like" in "I like it" vs "it was like, huge") are left to the formatting
/// model, which can read the sentence.
enum Disfluency {
    static let sounds: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "hmm", "mm", "ah"]

    /// Words people double on purpose: "very very", "no no", "that that".
    static let meantTwice: Set<String> = [
        "that", "had", "is", "do", "very", "really", "so", "no", "yes", "bye", "ha", "haha", "yeah", "okay",
        "well", "go", "now", "many", "much", "more", "far", "long", "too", "again", "please", "wait", "hey",
        "oh", "ah", "la", "knock", "tick", "tok", "chop", "night", "boo", "hip", "hear", "there",
    ]

    /// "like" right after these is filler for nearly everyone ("I have like three", "as like a").
    static let likeAfter: Set<String> = ["have", "as", "to", "right", "so"]

    private struct Token {
        var lead: String
        var core: String
        var trail: String
        var key: String { core.lowercased() }
        var endsSentence: Bool { trail.contains(where: { ".?!".contains($0) }) }
    }

    static func clean(_ text: String) -> String {
        var tokens = text.split(separator: " ", omittingEmptySubsequences: true).map { tokenize(String($0)) }
        guard !tokens.isEmpty else { return text }
        var drop = [Bool](repeating: false, count: tokens.count)

        for i in tokens.indices {
            let t = tokens[i]
            let prev = i > 0 ? tokens[i - 1] : nil
            let next = i + 1 < tokens.count ? tokens[i + 1] : nil

            if sounds.contains(t.key) { drop[i] = true; continue }

            // "b-but" → "but"; "w- we" → "we".
            if let fixed = stutterFix(t.core) { tokens[i].core = fixed; continue }
            if t.trail == "-", let next, !t.key.isEmpty, t.key.count <= 3, next.key.hasPrefix(t.key) {
                drop[i] = true; continue
            }

            if t.key == "like", let prev, likeAfter.contains(prev.key), prev.trail.isEmpty { drop[i] = true; continue }
            if t.key == "yeah", let prev, prev.key == "but", prev.trail.isEmpty || prev.trail == "," { drop[i] = true; continue }
            // ", you know," — bounded by commas, it's never the verb.
            if t.key == "you", let next, next.key == "know", t.trail.isEmpty,
               (prev?.trail == "," || t.lead.isEmpty && prev == nil), next.trail.hasPrefix(",") {
                drop[i] = true; drop[i + 1] = true
                continue
            }
        }

        // A word or a 2–3 word phrase said twice in a row: keep the second, which is the one the
        // speaker finished.
        for k in 1...3 {
            var i = 0
            while i + 2 * k <= tokens.count {
                let first = (i..<i + k).map { tokens[$0] }
                let second = (i + k..<i + 2 * k).map { tokens[$0] }
                let same = zip(first, second).allSatisfy { $0.key == $1.key && !$0.key.isEmpty }
                let undropped = (i..<i + 2 * k).allSatisfy { !drop[$0] }
                // Punctuation inside the first copy means the repeat crosses a sentence or a
                // list item ("Done. Done."), which is deliberate.
                let unbroken = first.dropLast().allSatisfy { $0.trail.isEmpty } && (first.last!.trail.isEmpty || first.last!.trail == ",")
                if same, undropped, unbroken, !(k == 1 && meantTwice.contains(first[0].key)) {
                    for j in i..<i + k { drop[j] = true }
                    i += 2 * k
                } else {
                    i += 1
                }
            }
        }
        return rebuild(tokens, drop: drop)
    }

    // MARK: Tokens

    private static func tokenize(_ raw: String) -> Token {
        let chars = Array(raw)
        var start = 0, end = chars.count
        while start < end, !(chars[start].isLetter || chars[start].isNumber) { start += 1 }
        while end > start, !(chars[end - 1].isLetter || chars[end - 1].isNumber) { end -= 1 }
        return Token(lead: String(chars[..<start]), core: String(chars[start..<end]), trail: String(chars[end...]))
    }

    /// "b-but" → "but", "I-I" → "I". Only when the bit before the hyphen is a short start of the
    /// word after it, so "well-being" and "e-mail" are left alone.
    private static func stutterFix(_ core: String) -> String? {
        let parts = core.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let last = parts.last, !last.isEmpty else { return nil }
        let heads = parts.dropLast()
        // "I-I", "we-we"; but "bye-bye" and "so-so" are words.
        if heads.allSatisfy({ $0.lowercased() == last.lowercased() }) {
            return last.count <= 2 && !meantTwice.contains(last.lowercased()) ? last : nil
        }
        guard last.count >= 2 else { return nil }
        guard heads.allSatisfy({ !$0.isEmpty && $0.count <= 2 && last.lowercased().hasPrefix($0.lowercased()) })
        else { return nil }
        // "e-mail" / "x-ray" style: a one-letter prefix that is a real compound.
        if heads.count == 1, ["e", "x", "t", "u", "a"].contains(heads.first!.lowercased()), last.count > 3 { return nil }
        return last
    }

    /// Joins the kept tokens, moving sentence-ending punctuation from a dropped token onto the
    /// word before it, and capitalising a word that now starts a sentence.
    private static func rebuild(_ tokens: [Token], drop: [Bool]) -> String {
        var out: [Token] = []
        var capitalizeNext = false
        for (i, token) in tokens.enumerated() {
            let sentenceStart = i == 0 || tokens[i - 1].endsSentence
            if drop[i] {
                if token.endsSentence, var last = out.popLast() {
                    // Keep the sentence end the dropped word carried.
                    let end = token.trail.filter { ".?!".contains($0) }
                    last.trail = last.trail.trimmingCharacters(in: CharacterSet(charactersIn: ",;:")) + end
                    out.append(last)
                }
                // A filler set off by commas takes one of them with it: "it was, you know, huge"
                // reads "it was huge".
                if token.trail.hasPrefix(","), var last = out.popLast() {
                    if last.trail == "," { last.trail = "" }
                    out.append(last)
                }
                if sentenceStart, token.core.first?.isUppercase == true { capitalizeNext = true }
                continue
            }
            var kept = token
            if capitalizeNext, let first = kept.core.first {
                kept.core = first.uppercased() + kept.core.dropFirst()
                capitalizeNext = false
            }
            // A comma that now follows nothing ("Um, so" → ", so") goes with the dropped word.
            if out.isEmpty || out.last!.endsSentence { kept.lead = kept.lead.trimmingCharacters(in: CharacterSet(charactersIn: ",")) }
            out.append(kept)
        }
        guard !out.isEmpty else { return "" }
        // A trailing comma left by a dropped last word.
        if out[out.count - 1].trail == "," { out[out.count - 1].trail = "" }
        return out.map { $0.lead + $0.core + $0.trail }.joined(separator: " ")
    }
}
