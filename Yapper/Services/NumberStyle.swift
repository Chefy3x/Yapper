import Foundation

/// Keeps number conversion to the cases people actually write in digits. Inverse text
/// normalisation turns every spoken number into digits, so "one room" becomes "1 room" and "the
/// first time" becomes "the 1st time", which nobody types. A single number word from one to nine
/// and the ordinals first to ninth go back to words; anything bigger, longer or with a unit
/// ("twenty five", "five percent", "two hundred dollars") keeps its digits.
enum NumberStyle {
    private static let smallDigit = try! NSRegularExpression(pattern: #"^[1-9](st|nd|rd|th)?$"#, options: [.caseInsensitive])

    /// `spoken` is the model's text, `written` the same text after normalisation.
    static func restrain(spoken: String, written: String) -> String {
        let a = spoken.split(separator: " ").map(String.init)
        let b = written.split(separator: " ").map(String.init)
        guard a != b else { return written }
        let matches = align(a.map(key), b.map(key))
        var out: [String] = []
        var pa = 0, pb = 0
        for (ma, mb) in matches + [(a.count, b.count)] {
            let spanA = Array(a[pa..<ma]), spanB = Array(b[pb..<mb])
            if !spanA.isEmpty, spanA.count != spanB.count, mergesSeparateNumbers(spanA) {
                // "three and five" → "35", "four and eight" → "48": two numbers joined into a
                // different one. The words as spoken are right; the conversion isn't.
                out += spanA
            } else if !spanB.isEmpty, spanA.count == spanB.count, spanB.allSatisfy(isSmall) {
                // Each small number back to its word ("the 2nd 1" → "the second one"), with the
                // punctuation the written form carries.
                for (wordToken, digitToken) in zip(spanA, spanB) {
                    let (lead, word, _) = parts(wordToken)
                    out.append(lead + word + parts(digitToken).trail)
                }
            } else {
                out += spanB
            }
            if mb < b.count { out.append(b[mb]) }
            pa = ma + 1; pb = mb + 1
        }
        return out.joined(separator: " ")
    }

    private static let units: Set<String> = ["zero", "oh", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
    /// Words after which "and" belongs to the number: "two hundred and five", "five dollars and fifty cents".
    private static let andJoins: Set<String> = ["hundred", "thousand", "million", "billion", "dollars", "dollar",
                                                "pounds", "euros", "bucks"]

    /// The spoken words are two or more numbers side by side, not one: joined by "and" where "and"
    /// can't be part of a number ("three and five"), or a run of single digits ("three five").
    static func mergesSeparateNumbers(_ spoken: [String]) -> Bool {
        let words = spoken.map { key($0) }
        for (i, w) in words.enumerated() where w == "and" {
            guard i > 0 else { continue }
            if !andJoins.contains(words[i - 1]) { return true }
        }
        return words.count >= 2 && words.allSatisfy(units.contains)
    }

    private static func isSmall(_ token: String) -> Bool {
        let core = parts(token).core
        return smallDigit.firstMatch(in: core, range: NSRange(core.startIndex..., in: core)) != nil
    }

    private static func key(_ token: String) -> String { parts(token).core.lowercased() }

    private static func parts(_ token: String) -> (lead: String, core: String, trail: String) {
        let chars = Array(token)
        var s = 0, e = chars.count
        while s < e, !(chars[s].isLetter || chars[s].isNumber) { s += 1 }
        while e > s, !(chars[e - 1].isLetter || chars[e - 1].isNumber) { e -= 1 }
        return (String(chars[..<s]), String(chars[s..<e]), String(chars[e...]))
    }

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
            else if t[i + 1][j] >= t[i][j + 1] { i += 1 } else { j += 1 }
        }
        return pairs
    }
}
