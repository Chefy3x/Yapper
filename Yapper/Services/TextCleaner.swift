import Foundation

/// Turns markdown (as emitted by Claude/ChatGPT/etc.) into TTS-ready plain text.
///
/// Per Yapper spec:
/// - Fenced code blocks: silently skipped, no announcement
/// - Inline code: keep contents, drop backticks
/// - Headings, bold/italic, links, lists, blockquotes: strip markers, keep text
/// - Tables, horizontal rules, images, math: stripped/skipped
/// - Paragraphs and list items: separated by blank lines so the TTS engine inserts a natural pause
enum TextCleaner {

    static func clean(_ raw: String) -> String {
        var lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        // 1. Strip fenced code blocks (``` ... ``` or ~~~ ... ~~~).
        lines = stripFencedCode(lines)

        // 2. Per-line transforms.
        let cleaned: [String] = lines.map { transformLine($0) }

        // 3. Collapse runs of empty lines to a single blank line so paragraph pauses stay natural.
        let collapsed = collapseBlankRuns(cleaned)

        // 4. Trim leading/trailing whitespace from the whole string.
        return collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Fenced code

    private static let fenceRegex = try! NSRegularExpression(pattern: #"^\s{0,3}(```+|~~~+)"#)

    private static func stripFencedCode(_ lines: [String]) -> [String] {
        var out: [String] = []
        var inFence = false
        var openFence = ""

        for line in lines {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = fenceRegex.firstMatch(in: line, range: range) {
                let fenceMarker = (line as NSString).substring(with: match.range(at: 1))
                if !inFence {
                    inFence = true
                    openFence = String(fenceMarker.prefix(1))   // ` or ~
                    continue
                }
                // Already inside a fence: only close on matching marker family.
                if fenceMarker.hasPrefix(openFence) {
                    inFence = false
                    openFence = ""
                    continue
                }
            }
            if inFence { continue }
            out.append(line)
        }
        return out
    }

    // MARK: - Per-line

    private static func transformLine(_ rawLine: String) -> String {
        var line = rawLine

        // Drop horizontal rules.
        if line.range(of: #"^\s*([-*_]\s*){3,}\s*$"#, options: .regularExpression) != nil {
            return ""
        }

        // Drop pure table rows / separators ( | a | b | , |---|---| ).
        // Heuristic: a line that starts and ends with | is treated as a table row.
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") {
            return ""
        }

        // Strip leading blockquote markers.
        line = line.replacingOccurrences(of: #"^\s*>\s?"#, with: "", options: .regularExpression)

        // Strip ATX heading markers (#, ##, ### …). Keep the heading text.
        line = line.replacingOccurrences(of: #"^\s*#{1,6}\s+"#, with: "", options: .regularExpression)

        // Strip leading list markers (-, *, +, 1. , 1) ).
        line = line.replacingOccurrences(of: #"^\s*([-*+]|\d+[.)])\s+"#, with: "", options: .regularExpression)

        // Inline transforms.
        line = stripInlineFormatting(line)

        return line
    }

    /// Remove markdown emphasis, code, links, and images while preserving the readable text.
    private static func stripInlineFormatting(_ s: String) -> String {
        var text = s

        // Images ![alt](url) -> drop entirely (we don't read alt by default).
        text = text.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)

        // Links [text](url) -> text
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)

        // Reference-style links [text][ref] -> text
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\[[^\]]*\]"#, with: "$1", options: .regularExpression)

        // Strip inline code backticks but keep the content. Handle 1+ backticks.
        text = text.replacingOccurrences(of: #"`+([^`]+)`+"#, with: "$1", options: .regularExpression)

        // Bold + italic combos. Order matters: longest first.
        text = text.replacingOccurrences(of: #"\*\*\*([^*]+)\*\*\*"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"___([^_]+)___"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"__([^_]+)__"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<!\w)\*([^*]+)\*(?!\w)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<!\w)_([^_]+)_(?!\w)"#, with: "$1", options: .regularExpression)

        // Strikethrough ~~text~~ -> text
        text = text.replacingOccurrences(of: #"~~([^~]+)~~"#, with: "$1", options: .regularExpression)

        // Collapse repeated internal whitespace.
        text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)

        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Whitespace

    private static func collapseBlankRuns(_ lines: [String]) -> [String] {
        var out: [String] = []
        var lastWasBlank = false
        for line in lines {
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if blank {
                if !lastWasBlank, !out.isEmpty { out.append("") }
                lastWasBlank = true
            } else {
                out.append(line)
                lastWasBlank = false
            }
        }
        return out
    }
}
