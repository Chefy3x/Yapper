import Foundation

/// Gets a recording ready for Whisper: cuts the silence around the speech, shortens long pauses
/// inside it, and lifts quiet speech to a level Whisper hears well.
///
/// Silence is where Whisper invents words ("Thank you.", a repeat of the last phrase), and a
/// far-off or soft-spoken mic is where it drops them. Pure, so the rules are tested on synthetic
/// audio. Runs only on recordings `TranscriptFilter.hasSpeech` already accepted: amplifying a
/// recording of nothing would only make the room louder.
enum AudioConditioner {
    /// Kept before the first and after the last voiced frame. Consonant onsets and trailing
    /// sounds sit under the voicing gate, so cutting at the gate itself clips words.
    static let edgePad: Double = 0.4
    /// A pause inside the speech longer than this is shortened…
    static let longPause: Double = 2.0
    /// …to this, split evenly either side of the cut.
    static let keptPause: Double = 1.0
    /// The speech level aimed for: about −22 dBFS, where Whisper's training audio sits.
    static let targetSpeechRMS: Float = 0.08
    /// Never boosts more than this (+18 dB): beyond it the mic is reporting noise, not a voice.
    static let maxGain: Float = 8
    /// The loudest sample after the boost stays under this, so nothing clips.
    static let peakCeiling: Float = 0.95

    struct Result: Equatable, Sendable {
        var samples: [Float]
        /// Seconds removed by trimming and pause-shortening.
        var removedSeconds: Double
        var gain: Float
    }

    static func condition(_ samples: [Float], sampleRate: Double = 16_000) -> Result {
        let unchanged = Result(samples: samples, removedSeconds: 0, gain: 1)
        let levels = TranscriptFilter.frameLevels(samples, sampleRate: sampleRate)
        guard !levels.isEmpty else { return unchanged }
        let gate = TranscriptFilter.speechGate(levels)
        // Silence for cutting purposes is far stricter than voicing: a soft word between two
        // loud sentences sits under the voicing gate but well above the room. It's measured
        // from the quietest frames (5th percentile), not the 20th, because in a recording that
        // is talking most of the time the 20th percentile is already speech.
        let sorted = levels.sorted()
        let silence = sorted[sorted.count / 20]
        let quiet = min(max(silence * 2, 0.004), gate * 0.5)

        let voiced = levels.indices.filter { levels[$0] > gate }
        guard !voiced.isEmpty else { return unchanged }
        // The edges are cut only where the recording is silent all the way out. Measured from
        // the last frame above the silence line, not the last loud one: a soft "I don't know
        // why" after a pause sits under the voicing gate, and cutting at the gate lost it.
        guard let firstVoiced = levels.firstIndex(where: { $0 > quiet }),
              let lastVoiced = levels.lastIndex(where: { $0 > quiet }) else { return unchanged }

        let frame = Int(sampleRate * TranscriptFilter.frameSeconds)
        let pad = Int((edgePad / TranscriptFilter.frameSeconds).rounded())
        let startFrame = max(0, firstVoiced - pad)
        let endFrame = min(levels.count, lastVoiced + 1 + pad)   // exclusive

        // Frame ranges to keep, with long quiet runs shortened.
        let longRun = Int((longPause / TranscriptFilter.frameSeconds).rounded())
        let keepHalf = Int((keptPause / 2 / TranscriptFilter.frameSeconds).rounded())
        var keep: [Range<Int>] = []
        var runStart: Int?
        var cursor = startFrame
        for f in startFrame..<endFrame {
            if levels[f] <= quiet {
                if runStart == nil { runStart = f }
                continue
            }
            if let rs = runStart, f - rs > longRun {
                keep.append(cursor..<(rs + keepHalf))
                cursor = f - keepHalf
            }
            runStart = nil
        }
        keep.append(cursor..<endFrame)

        var out: [Float] = []
        out.reserveCapacity((endFrame - startFrame) * frame)
        for range in keep {
            let lo = range.lowerBound * frame
            // The last kept frame extends to the end of the samples when it is the recording's
            // last frame, so a trailing partial frame isn't lost.
            let hi = range.upperBound == levels.count ? samples.count : range.upperBound * frame
            guard lo < hi else { continue }
            out.append(contentsOf: samples[lo..<hi])
        }

        // Gain from the median voiced level, so one shout doesn't decide it.
        let voicedLevels = voiced.map { levels[$0] }.sorted()
        let speechRMS = voicedLevels[voicedLevels.count / 2]
        var peak: Float = 0
        for s in out { peak = max(peak, abs(s)) }
        var gain = speechRMS > 0 ? targetSpeechRMS / speechRMS : 1
        gain = min(gain, maxGain)
        if peak > 0 { gain = min(gain, peakCeiling / peak) }
        gain = max(gain, 1)   // loud is fine; only quiet speech gets help
        if gain > 1.01 {
            for i in out.indices { out[i] *= gain }
        } else {
            gain = 1
        }

        let removed = Double(samples.count - out.count) / sampleRate
        return Result(samples: out, removedSeconds: removed, gain: gain)
    }
}
