import Foundation

/// One decoded segment with the confidence metadata Whisper attaches to it. Mirrors the fields
/// WhisperKit exposes, without importing WhisperKit — so the filter is testable in isolation.
struct TranscriptSegment: Equatable, Sendable {
    var text: String
    var avgLogprob: Float
    var noSpeechProb: Float
    var compressionRatio: Float
    /// Seconds from the start of the recording. Nil when the decoder gave no timestamp.
    var start: Float? = nil
}

/// Turns Whisper's raw segments into text fit to type into a chat box.
///
/// Whisper is confident on real speech and audibly unsure on noise: a TV in the room, a cough, or
/// pure silence produce segments that fail these gates, and silence in particular produces
/// stock hallucinations ("Thank you.", "Thanks for watching."). The thresholds are OpenAI's own
/// decode-fallback defaults.
///
/// How hard they bite depends on whether the audio itself held speech. When it did, only
/// OpenAI's real silence rule applies (no-speech AND low confidence), because a mumbled word,
/// a name, or a short "Okay." is still something the user said, and dropping it reads as the
/// app not listening. When the audio was near-silent, any one gate drops the segment and the
/// stock phrases go too.
enum TranscriptFilter {
    static let noSpeechProbMax: Float = 0.6
    static let avgLogprobMin: Float = -1.0
    static let compressionRatioMax: Float = 2.4

    /// RMS a 20 ms frame must clear to count as voiced. Matches the VAD's onset floor.
    static let speechFrameRMS: Float = 0.012
    /// Voiced audio needed before the recording is treated as speech: about one short word.
    static let speechMinSeconds: Double = 0.25

    /// True when the recording contains enough voiced frames to be someone talking, measured
    /// against the recording's own quiet floor so a noisy room doesn't count as speech.
    static func hasSpeech(_ samples: [Float], sampleRate: Double = 16_000) -> Bool {
        let levels = frameLevels(samples, sampleRate: sampleRate)
        guard !levels.isEmpty else { return false }
        let gate = speechGate(levels)
        let voiced = levels.filter { $0 > gate }.count
        return Double(voiced) * frameSeconds >= speechMinSeconds
    }

    static let frameSeconds = 0.02

    /// RMS of each 20 ms frame. A trailing partial frame is dropped.
    static func frameLevels(_ samples: [Float], sampleRate: Double = 16_000) -> [Float] {
        let frame = Int(sampleRate * frameSeconds)
        guard frame > 0, samples.count >= frame else { return [] }
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / frame)
        var i = 0
        while i + frame <= samples.count {
            var sum: Float = 0
            for s in samples[i..<(i + frame)] { sum += s * s }
            levels.append((sum / Float(frame)).squareRoot())
            i += frame
        }
        return levels
    }

    /// The level a frame must clear to be voiced, learned from the recording's own quiet floor.
    static func speechGate(_ levels: [Float]) -> Float {
        let floor = roomFloor(levels)
        // Capped so a recording that is talking end to end (no quiet frames to learn the room
        // from) can't raise the bar above normal speaking level.
        return max(speechFrameRMS, min(floor * 2.5, 0.04))
    }

    /// 20th-percentile frame level: the room with nobody talking.
    static func roomFloor(_ levels: [Float]) -> Float {
        guard !levels.isEmpty else { return 0 }
        return levels.sorted()[levels.count / 5]
    }

    /// Phrases Whisper emits for silence or music, lowercased and stripped of punctuation.
    static let hallucinations: Set<String> = [
        "thank you", "thanks", "thanks for watching", "thank you for watching",
        "thank you for listening", "thanks for listening", "you", "bye", "goodbye",
        "subtitles by the amara org community", "music", "blank audio", "silence",
        "so", "okay", "the end"
    ]

    /// `audioHasSpeech` comes from `hasSpeech(_:)` on the same recording. Leave it false when
    /// unknown: that is the strict reading. `audioSeconds` is the recording's length; a segment
    /// that starts after it can only be invented, because Whisper decodes a window padded with
    /// silence out to 30 s.
    static func join(_ segments: [TranscriptSegment], audioHasSpeech: Bool = false,
                     audioSeconds: Double? = nil) -> String {
        var kept: [String] = []
        for seg in segments {
            let cleaned = stripSpecialTokens(seg.text)
            guard !cleaned.isEmpty else { continue }
            if let audioSeconds, let start = seg.start, Double(start) >= audioSeconds { continue }
            let unsure = seg.avgLogprob < avgLogprobMin
            let silent = seg.noSpeechProb > noSpeechProbMax
            if audioHasSpeech ? (silent && unsure) : (silent || unsure) { continue }
            if seg.compressionRatio > compressionRatioMax { continue }   // "the the the the"
            kept.append(cleaned)
        }
        let joined = kept.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return "" }
        // "[BLANK_AUDIO]", "(music)": Whisper's sound tags are never words, speech or not.
        if joined.range(of: #"^[\[(][^\])]*[\])]$"#, options: .regularExpression) != nil { return "" }
        if audioHasSpeech { return joined }
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
