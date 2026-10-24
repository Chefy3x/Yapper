import Testing
import Foundation

/// The level rules on synthetic audio, and the voice decision with a stand-in similarity.
struct BackgroundSpeechGateTests {
    private let rate = 16_000.0

    /// A 200 Hz tone at `amplitude` for each word, 0.3 s per word with 0.2 s of silence after,
    /// so no word's search window reaches its neighbour's sound.
    private func recording(_ amplitudes: [Float]) -> (words: [BackgroundSpeechGate.Word], samples: [Float]) {
        var samples: [Float] = []
        var words: [BackgroundSpeechGate.Word] = []
        for (i, a) in amplitudes.enumerated() {
            let start = Double(samples.count) / rate
            samples += (0..<Int(0.3 * rate)).map { a * sin(2 * .pi * 200 * Float($0) / Float(rate)) }
            samples += [Float](repeating: 0, count: Int(0.2 * rate))
            words.append(.init(text: "w\(i)", start: start + 0.05, end: start + 0.25))
        }
        return (words, samples)
    }

    private let loud: Float = 0.2      // ≈ −17 dBFS RMS
    private let quiet: Float = 0.03    // ≈ −33 dBFS: 16 dB under

    @Test func levelsFollowEachWord() {
        let (words, samples) = recording([loud, quiet, loud])
        let levels = BackgroundSpeechGate.levels(of: words, samples: samples)
        #expect(levels[0] > levels[1] + 12)
        #expect(abs(levels[0] - levels[2]) < 0.5)
    }

    @Test func longQuietRunIsSuspect() {
        let (words, samples) = recording(Array(repeating: loud, count: 8) + Array(repeating: quiet, count: 7) + [loud, loud])
        let levels = BackgroundSpeechGate.levels(of: words, samples: samples)
        #expect(BackgroundSpeechGate.suspectRuns(levels: levels) == [8..<15])
    }

    @Test func shortQuietRunIsNot() {
        let (words, samples) = recording(Array(repeating: loud, count: 8) + Array(repeating: quiet, count: 5) + [loud, loud])
        let levels = BackgroundSpeechGate.levels(of: words, samples: samples)
        #expect(BackgroundSpeechGate.suspectRuns(levels: levels).isEmpty)
    }

    @Test func tooFewWordsAreNeverJudged() {
        let (words, samples) = recording([loud, quiet, quiet, quiet, quiet])
        let levels = BackgroundSpeechGate.levels(of: words, samples: samples)
        #expect(BackgroundSpeechGate.suspectRuns(levels: levels).isEmpty)
        #expect(BackgroundSpeechGate.loudWords(levels: levels).isEmpty)
    }

    @Test func loudWordsAreTheSpeaker() {
        let (words, samples) = recording(Array(repeating: loud, count: 6) + Array(repeating: quiet, count: 6))
        let levels = BackgroundSpeechGate.levels(of: words, samples: samples)
        #expect(BackgroundSpeechGate.loudWords(levels: levels) == Array(0..<6))
    }

    @Test func quietRunInAnotherVoiceIsDropped() {
        let (words, samples) = recording(Array(repeating: loud, count: 8) + Array(repeating: quiet, count: 7))
        let levels = BackgroundSpeechGate.levels(of: words, samples: samples)
        let gated = BackgroundSpeechGate.keptWords(words, levels: levels, samples: samples) { _ in 0.05 }
        #expect(gated.dropped == 7)
        #expect(gated.words.map(\.text) == (0..<8).map { "w\($0)" })
    }

    @Test func quietRunInTheUsersVoiceStays() {
        let (words, samples) = recording(Array(repeating: loud, count: 8) + Array(repeating: quiet, count: 7))
        let levels = BackgroundSpeechGate.levels(of: words, samples: samples)
        let gated = BackgroundSpeechGate.keptWords(words, levels: levels, samples: samples) { _ in 0.6 }
        #expect(gated.dropped == 0)
        #expect(gated.words == words)
    }

    @Test func unknownVoiceKeepsEverything() {
        let (words, samples) = recording(Array(repeating: loud, count: 8) + Array(repeating: quiet, count: 7))
        let levels = BackgroundSpeechGate.levels(of: words, samples: samples)
        #expect(BackgroundSpeechGate.keptWords(words, levels: levels, samples: samples) { _ in nil }.dropped == 0)
    }

    @Test func audioOfWordsIsPaddedAndJoined() {
        let samples = [Float](repeating: 1, count: 16_000)
        let words = [BackgroundSpeechGate.Word(text: "a", start: 0.2, end: 0.3),
                     BackgroundSpeechGate.Word(text: "b", start: 0.6, end: 0.7)]
        // Each word ±0.1 s: 0.3 s apiece.
        #expect(BackgroundSpeechGate.audio(of: words, in: samples).count == 9_600)
    }

    @Test func keptTextStartsWithACapital() {
        let words = ["you", "think", "two", "seconds", "is", "too", "little"]
            .map { BackgroundSpeechGate.Word(text: $0, start: 0, end: 0) }
        #expect(BackgroundSpeechGate.text(words) == "You think two seconds is too little")
    }
}

struct VoicePrintTests {
    @Test func notReadyUntilEnoughDictations() {
        var print = VoicePrint(model: "m")
        for _ in 0..<(VoicePrint.readyAfter - 1) { print.learn([1, 0, 0]) }
        #expect(print.similarity([1, 0, 0]) == nil)
        print.learn([1, 0, 0])
        #expect(print.similarity([1, 0, 0]).map { abs($0 - 1) < 1e-5 } == true)
    }

    @Test func otherVoicesScoreLow() {
        var print = VoicePrint(model: "m")
        for _ in 0..<VoicePrint.readyAfter { print.learn([1, 0.1, 0]) }
        #expect((print.similarity([0, 0, 1]) ?? 1) < 0.1)
        #expect((print.similarity([2, 0.2, 0]) ?? 0) > 0.99)   // scale doesn't matter
    }

    @Test func followsTheNewestVoice() {
        var print = VoicePrint(model: "m")
        for _ in 0..<VoicePrint.memory { print.learn([1, 0]) }
        for _ in 0..<VoicePrint.memory { print.learn([0, 1]) }
        #expect((print.similarity([0, 1]) ?? 0) > (print.similarity([1, 0]) ?? 1))
    }

    @Test func storeIgnoresAnotherModelsPrint() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voiceprint-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = VoicePrintStore(url: url)
        var print = VoicePrint(model: "a")
        print.learn([1, 0])
        store.save(print)
        #expect(store.load(model: "a") == print)
        #expect(store.load(model: "b").count == 0)
    }
}
