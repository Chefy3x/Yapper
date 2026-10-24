import Foundation

/// Drops the words other people said: a TV, a show on someone's phone, a conversation nearby.
///
/// Parakeet writes down every voice it can make out, so talk behind the user lands in their
/// message. Two signals together tell it apart:
///   • Level. The user is close to the mic and the room is not, so background talk comes out as
///     a run of words well under the recording's speaking level. Level alone isn't enough: on
///     the user's 1,400 saved dictations their own voice drops just as far when they lean back
///     or trail off at the end of a thought, and every setting that caught a show also cut the
///     user in dozens of recordings.
///   • Voice. Each quiet run is compared with the user's voice (`VoicePrint`), and only a run
///     that doesn't sound like them is dropped. Replayed over those dictations in order, a show
///     playing in the room scored −0.06 to 0.07 and the user's own quiet runs never fell below
///     0.30; that one recording was the only one changed.
///
/// The level rules are pure and tested on synthetic audio; the voice comparison is passed in.
enum BackgroundSpeechGate {
    /// One decoded word and where it sits in the recording, in seconds.
    struct Word: Equatable, Sendable {
        var text: String
        var start: Double
        var end: Double
    }

    /// A word this far under the speaking level is quiet enough to be someone else.
    static let quietBelowDB: Float = 10
    /// Consecutive quiet words before the voice is checked. Shorter runs are a soft word or two
    /// inside the user's own speech, and too little audio to judge a voice by anyway.
    static let minRun = 6
    /// The speaking level is this percentile of the word levels. Well above the median, so a
    /// long stretch of background talk can't pull it down to its own level.
    static let referencePercentile = 0.85
    /// Words this close to the speaking level are the user for certain: what `VoicePrint` learns from.
    static let loudWithinDB: Float = 6
    /// A quiet run that matches the user's voice less than this is someone else. Halfway between
    /// the show (0.07 at most) and the user's own quietest run (0.30).
    static let voiceMatchMin: Float = 0.18
    /// Searched around each word's decoder timestamps, which mark where a token was emitted, not
    /// the edges of the sound.
    static let searchPad: Double = 0.12
    /// Kept around each word when its audio is cut out for a voice check.
    static let audioPad: Double = 0.1
    /// Fewer words than this and there is no speaking level to judge against.
    static let minWords = 6

    /// Each word's level in dBFS: the loudest 20 ms frame near it. The peak, not the mean, so a
    /// word whose timestamps land partly in a pause still reads at the level it was spoken.
    static func levels(of words: [Word], samples: [Float], sampleRate: Double = 16_000) -> [Float] {
        let frames = TranscriptFilter.frameLevels(samples, sampleRate: sampleRate)
        let step = TranscriptFilter.frameSeconds
        return words.map { word in
            guard !frames.isEmpty else { return -120 }
            let lo = max(0, min(frames.count - 1, Int(((word.start - searchPad) / step).rounded(.down))))
            let hi = max(lo, min(frames.count - 1, Int(((word.end + searchPad) / step).rounded(.up))))
            let peak = frames[lo...hi].max() ?? 0
            return 20 * log10(max(peak, 1e-6))
        }
    }

    /// The speaking level the words are judged against, in dBFS.
    static func reference(_ levels: [Float]) -> Float {
        let sorted = levels.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * referencePercentile))]
    }

    /// Runs of quiet words long enough to be someone else, as word index ranges.
    static func suspectRuns(levels: [Float]) -> [Range<Int>] {
        guard levels.count >= minWords else { return [] }
        let bar = reference(levels) - quietBelowDB
        var runs: [Range<Int>] = []
        var i = 0
        while i < levels.count {
            guard levels[i] < bar else { i += 1; continue }
            var j = i
            while j < levels.count, levels[j] < bar { j += 1 }
            if j - i >= minRun { runs.append(i..<j) }
            i = j
        }
        return runs
    }

    /// Indices of the words spoken near the speaking level: the user, whatever else is in the room.
    static func loudWords(levels: [Float]) -> [Int] {
        guard levels.count >= minWords else { return [] }
        let bar = reference(levels) - loudWithinDB
        return levels.indices.filter { levels[$0] >= bar }
    }

    /// The audio under the given words, each padded, joined end to end.
    static func audio(of words: some Sequence<Word>, in samples: [Float], sampleRate: Double = 16_000) -> [Float] {
        words.flatMap { word -> ArraySlice<Float> in
            let lo = max(0, Int(((word.start - audioPad) * sampleRate).rounded()))
            let hi = min(samples.count, Int(((word.end + audioPad) * sampleRate).rounded()))
            return lo < hi ? samples[lo..<hi] : []
        }
    }

    /// The words left once every suspect run that doesn't sound like the user is gone.
    /// `similarity` scores a run's audio against the user's voice; nil (no voice learned yet, or
    /// the check failed) keeps the run, so the gate only ever removes what it is sure of.
    static func keptWords(_ words: [Word], levels: [Float], samples: [Float],
                          similarity: ([Float]) -> Float?) -> (words: [Word], dropped: Int) {
        var drop = IndexSet()
        for run in suspectRuns(levels: levels) {
            guard let score = similarity(audio(of: words[run], in: samples)), score < voiceMatchMin else { continue }
            drop.insert(integersIn: run)
        }
        guard !drop.isEmpty else { return (words, 0) }
        return (words.indices.filter { !drop.contains($0) }.map { words[$0] }, drop.count)
    }

    /// The kept words as a sentence. Each word carries its own punctuation from the decoder; a
    /// kept run that starts mid-sentence gets a capital so it reads as a fresh start.
    static func text(_ words: [Word]) -> String {
        var out = words.map(\.text).joined(separator: " ")
        if let first = out.first, first.isLowercase { out.replaceSubrange(...out.startIndex, with: String(first).uppercased()) }
        return out
    }
}
