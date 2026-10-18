import Foundation

/// Turns a spoken enumeration into a list: "first, … second, … third, …" or "number one, …
/// number two, …". Said that way, a list is what's meant nearly every time, and rules get it
/// right every time where the 2B model only sometimes does.
///
/// A counting word only counts when it opens a clause and is followed the way list markers are
/// ("First, we…", "second is…", "number two:"), and only as part of a run that starts at one
/// and goes up by one. "The first time, the second time" and "my number one priority" are
/// left as they are.
enum SpokenLists {
    private static let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]
    private static let adverbs = ["firstly", "secondly", "thirdly", "fourthly", "fifthly"]
    private static let cardinals = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
    /// May close a run of at least two items.
    private static let closers: Set<String> = ["lastly", "finally"]
    /// Words that can sit between a clause start and the marker: "So first, …", "And second, …".
    private static let openers: Set<String> = ["so", "and", "then", "okay", "ok", "also", "now", "um", "uh", "well", "but"]

    private struct Word {
        let range: Range<String.Index>
        let core: String
        var key: String { core.lowercased() }
    }

    private struct Marker {
        let position: Int        // 1-based list position; 0 for a closer
        let start: String.Index  // where the marker phrase begins (including any opener)
        let end: String.Index    // where the item text begins
    }

    static func format(_ text: String, mode: FormatMode) -> String? {
        let words = tokenize(text)
        guard words.count >= 4 else { return nil }
        let markers = findMarkers(text, words)
        guard markers.count >= 2 else { return nil }

        // The intro: whatever came before the first marker, minus a dangling "so" or "and".
        var intro = String(text[..<markers[0].start]).trimmingCharacters(in: .whitespacesAndNewlines)
        intro = trimTrailing(intro, words: openers)
        intro = intro.trimmingCharacters(in: CharacterSet(charactersIn: ",;: "))
        let introIsFiller = intro.split(separator: " ").allSatisfy { openers.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) }
        if introIsFiller { intro = "" }

        var items: [String] = []
        var after = ""
        for (i, marker) in markers.enumerated() {
            let end = i + 1 < markers.count ? markers[i + 1].start : text.endIndex
            var item = String(text[marker.end..<end])
            if i == markers.count - 1, let stop = sentenceEnd(in: item) {
                // The last item is its own sentence; anything said after it stays as prose.
                after = String(item[stop...]).trimmingCharacters(in: .whitespacesAndNewlines)
                item = String(item[..<stop])
            }
            item = cleanItem(item)
            guard !item.isEmpty else { return nil }
            items.append(item)
        }

        var out = ""
        if !intro.isEmpty {
            out = intro.hasSuffix(".") || intro.hasSuffix("?") || intro.hasSuffix("!") ? intro : intro + ":"
            out += mode.allowsLineBreaks ? "\n" : " "
        }
        out += mode.listLines(items)
        if mode == .terminal { out += "." }
        if !after.isEmpty { out += mode.allowsLineBreaks ? "\n\n" + after : " " + after }
        return out
    }

    // MARK: Finding the markers

    private static func findMarkers(_ text: String, _ words: [Word]) -> [Marker] {
        var found: [Marker] = []
        var expected = 1
        var i = 0
        while i < words.count {
            let w = words[i]
            var position: Int?
            var length = 1
            if expected <= ordinals.count, w.key == ordinals[expected - 1] || (expected <= adverbs.count && w.key == adverbs[expected - 1]) {
                position = expected
            } else if w.key == "number", i + 1 < words.count, expected <= cardinals.count,
                      words[i + 1].key == cardinals[expected - 1] || words[i + 1].key == String(expected) {
                position = expected
                length = 2
            } else if found.count >= 2, closers.contains(w.key) {
                position = 0
            }
            if let position, opensClause(text, words, i), let itemStart = markerTail(text, words, i + length - 1) {
                var start = w.range.lowerBound
                // Pull a clause-opening "so"/"and" into the marker so it doesn't trail the item before.
                if i > 0, openers.contains(words[i - 1].key), opensClause(text, words, i - 1), !text[words[i - 1].range].hasSuffix(",") {
                    start = words[i - 1].range.lowerBound
                }
                found.append(Marker(position: position, start: start, end: itemStart))
                if position == 0 { break }
                expected += 1
                i += length
                continue
            }
            i += 1
        }
        // A run must start at one: "second" alone isn't a list.
        return found.first?.position == 1 ? found : []
    }

    /// At the start of the text, after sentence or clause punctuation, or after an opener that is.
    private static func opensClause(_ text: String, _ words: [Word], _ i: Int) -> Bool {
        guard i > 0 else { return true }
        let gap = text[words[i - 1].range.upperBound..<words[i].range.lowerBound]
        if gap.contains(where: { ".,;:!?".contains($0) }) { return true }
        if openers.contains(words[i - 1].key) { return opensClause(text, words, i - 1) }
        return false
    }

    /// Where the item starts if the marker is followed like a list marker, else nil.
    private static func markerTail(_ text: String, _ words: [Word], _ last: Int) -> String.Index? {
        let afterMarker = words[last].range.upperBound
        let rest = text[afterMarker...]
        let trimmed = rest.drop(while: { $0 == " " })
        if trimmed.hasPrefix(",") || trimmed.hasPrefix(":") {
            return text.index(after: trimmed.startIndex)
        }
        guard last + 1 < words.count else { return nil }
        let next = words[last + 1]
        // "first is the video edit", "first off, …", "first of all, …"
        if ["is", "was"].contains(next.key) { return next.range.upperBound }
        if next.key == "off", text[next.range.upperBound...].hasPrefix(",") {
            return text.index(after: next.range.upperBound)
        }
        if next.key == "of", last + 2 < words.count, words[last + 2].key == "all" {
            let end = words[last + 2].range.upperBound
            return text[end...].hasPrefix(",") ? text.index(after: end) : end
        }
        return nil
    }

    // MARK: Items

    private static func cleanItem(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ",;: "))
        s = trimTrailing(s, words: ["and", "then", "so", "also"])
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ".,;: "))
        guard let first = s.first else { return "" }
        return first.uppercased() + s.dropFirst()
    }

    private static func trimTrailing(_ s: String, words: Set<String>) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while true {
            let stripped = out.trimmingCharacters(in: CharacterSet(charactersIn: ",;: "))
            guard let space = stripped.lastIndex(of: " ") ?? (stripped.isEmpty ? nil : stripped.startIndex) else { return stripped }
            let lastWord = stripped[space...].trimmingCharacters(in: .whitespaces).lowercased()
            guard words.contains(lastWord) else { return stripped }
            out = String(stripped[..<space])
            if space == stripped.startIndex { return "" }
        }
    }

    /// The end of the first sentence in `s` (just past its period), when there's more after it.
    private static func sentenceEnd(in s: String) -> String.Index? {
        var i = s.startIndex
        while i < s.endIndex {
            if ".!?".contains(s[i]) {
                let next = s.index(after: i)
                if next < s.endIndex, s[next] == " ", !s[next...].trimmingCharacters(in: .whitespaces).isEmpty { return next }
            }
            i = s.index(after: i)
        }
        return nil
    }

    private static func tokenize(_ text: String) -> [Word] {
        var out: [Word] = []
        var i = text.startIndex
        while i < text.endIndex {
            guard text[i].isLetter || text[i].isNumber else { i = text.index(after: i); continue }
            var j = i
            while j < text.endIndex, text[j].isLetter || text[j].isNumber || text[j] == "'" || text[j] == "’" { j = text.index(after: j) }
            out.append(Word(range: i..<j, core: String(text[i..<j])))
            i = j
        }
        return out
    }
}
