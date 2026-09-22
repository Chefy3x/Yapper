import Foundation

/// One decoded segment with the confidence metadata Whisper attaches to it. Mirrors the fields
/// WhisperKit exposes, without importing WhisperKit — so the filter is testable in isolation.
struct TranscriptSegment: Equatable, Sendable {
    var text: String
    var avgLogprob: Float
    var noSpeechProb: Float
    var compressionRatio: Float
}

/// Turns Whisper's raw segments into text fit to type into a chat box.
///
/// Whisper is confident on real speech and audibly unsure on noise: a TV in the room, a cough, or
/// pure silence produce segments that fail these gates, and silence in particular produces
/// stock hallucinations ("Thank you.", "Thanks for watching."). The thresholds are OpenAI's own
/// decode-fallback defaults; foreground speech clears them with wide margin.
enum TranscriptFilter {
    static let noSpeechProbMax: Float = 0.6
    static let avgLogprobMin: Float = -1.0
    static let compressionRatioMax: Float = 2.4

    /// Phrases Whisper emits for silence or music, lowercased and stripped of punctuation.
    static let hallucinations: Set<String> = [
        "thank you", "thanks", "thanks for watching", "thank you for watching",
        "thank you for listening", "thanks for listening", "you", "bye", "goodbye",
        "subtitles by the amara org community", "music", "blank audio", "silence",
        "so", "okay", "the end"
    ]

    static func join(_ segments: [TranscriptSegment]) -> String {
        var kept: [String] = []
        for seg in segments {
            let cleaned = stripSpecialTokens(seg.text)
            guard !cleaned.isEmpty else { continue }
            if seg.noSpeechProb > noSpeechProbMax { continue }
            if seg.avgLogprob < avgLogprobMin { continue }
            if seg.compressionRatio > compressionRatioMax { continue }
            kept.append(cleaned)
        }
        let joined = kept.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return isLikelyHallucination(joined) ? "" : joined
    }

    /// `<|startoftranscript|>`, `<|en|>`, `<|0.00|>` and friends all share the `<|…|>` shape.
    static func stripSpecialTokens(_ text: String) -> String {
        text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True for the stock phrases Whisper produces from silence. Only short outputs qualify —
    /// a real sentence that happens to end in "thank you" is never dropped.
    static func isLikelyHallucination(_ text: String) -> Bool {
        let normalized = text.lowercased()
            .replacingOccurrences(of: "_", with: " ")   // [BLANK_AUDIO] → "blank audio"
            .replacingOccurrences(of: #"[^a-z0-9 ]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { return true }
        return hallucinations.contains(normalized)
    }
}
