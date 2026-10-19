import Foundation

/// Makes a transcript fit where it lands. A dictation is written as a sentence ("Send it
/// tomorrow."), but dropped into the middle of one it should read "send it tomorrow" with a space
/// in front: lowercase when the sentence is already going, a space only when the text before needs
/// one, and no closing period when more of the sentence follows the cursor.
///
/// `before` and `after` are the field's text on either side of the cursor (or of the selection
/// the dictation replaces). Nil means the app wouldn't say, and the text goes in unchanged.
enum InsertionFit {
    private static let opensSentence: Set<Character> = [".", "!", "?", "…"]
    private static let noSpaceAfter: Set<Character> = ["(", "[", "{", "\"", "'", "“", "‘", "/", "-", "#", "@"]
    private static let pronounI: Set<String> = ["i", "i'm", "i'll", "i've", "i'd", "i’m", "i’ll", "i’ve", "i’d"]

    static func fit(_ text: String, before: String?, after: String?,
                    isDictionaryWord: (String) -> Bool) -> String {
        guard let before, !text.isEmpty else { return text }
        var out = text

        // A list starts on its own line.
        if out.contains("\n") {
            if let last = before.last, last != "\n" { return "\n" + out }
            return out
        }

        let trimmedBefore = before.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
        // The current line so far is only markup ("$ ", "> ", "- "): a prompt or a bullet, so
        // the dictation starts it.
        let line = trimmedBefore.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let lineIsMarkup = !line.isEmpty && !line.contains { $0.isLetter || $0.isNumber }
            && line.contains { "$>%#❯›-*•".contains($0) }
        let atStart = trimmedBefore.isEmpty || trimmedBefore.last == "\n" || lineIsMarkup
            || trimmedBefore.last.map { opensSentence.contains($0) } == true

        if !atStart { out = lowercaseFirstWord(out, isDictionaryWord: isDictionaryWord) }

        if let last = before.last, !last.isWhitespace, !noSpaceAfter.contains(last) {
            out = " " + out
        }

        if let after, let next = after.first {
            if next.isLetter || next.isNumber {
                // More of the sentence follows: no full stop in the middle of it, and a space
                // before the word that comes next.
                if out.hasSuffix(".") { out.removeLast() }
                out += " "
            } else if ".,;:!?".contains(next) {
                while let end = out.last, ".,;:!?".contains(end) { out.removeLast() }
            }
        }
        return out
    }

    /// "Send it" → "send it", unless the word is "I", an acronym, or a name the dictionary
    /// doesn't know ("Priya", "WhisperKit"), which keep their capital.
    private static func lowercaseFirstWord(_ text: String, isDictionaryWord: (String) -> Bool) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        let word = String(text.prefix { !$0.isWhitespace && !",.;:!?".contains($0) })
        let lower = word.lowercased()
        if pronounI.contains(lower) { return text }
        if word.count > 1, word.dropFirst().contains(where: \.isUppercase) { return text }   // "GPT", "iOS"-like
        guard isDictionaryWord(lower) else { return text }
        return first.lowercased() + text.dropFirst()
    }
}
