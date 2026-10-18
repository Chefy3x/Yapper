import Testing
import Foundation

// The start sound plays into an open mic. These check that the notches take it back out of
// the recording and leave speech-band audio alone.
struct StartCueTests {
    private let rate = 16_000.0

    private func energy(_ x: ArraySlice<Float>) -> Double { x.reduce(0) { $0 + Double($1 * $1) } }

    /// A crude voiced sound: a 140 Hz buzz with harmonics up to 4 kHz, falling off with frequency.
    private func voice(seconds: Double) -> [Float] {
        (0..<Int(seconds * rate)).map { i in
            let t = Double(i) / rate
            var v = 0.0
            for h in 1...28 { v += sin(2 * .pi * 140 * Double(h) * t) / Double(h) }
            return Float(v * 0.05)
        }
    }

    @Test func theCueIsRemovedFromTheRecording() {
        var recording = [Float](repeating: 0, count: Int(2 * rate))
        let cue = StartCue.render(sampleRate: rate, gain: 0.3)
        let at = Int(0.5 * rate)
        for (i, s) in cue.enumerated() { recording[at + i] += s }
        let window = at..<(at + cue.count)
        let before = energy(recording[window])

        StartCue.remove(from: &recording, cueOffset: 0.5, sampleRate: rate)
        let after = energy(recording[window])
        // At least 30 dB quieter.
        #expect(after < before / 1_000)
    }

    @Test func speechAroundTheCueKeepsItsEnergy() {
        let original = voice(seconds: 2)
        var filtered = original
        StartCue.remove(from: &filtered, cueOffset: 0.5, sampleRate: rate)
        let a = energy(original[...]), b = energy(filtered[...])
        #expect(b / a > 0.93)
        // And outside the window not one sample changes.
        #expect(Array(filtered[Int(1.4 * rate)...]) == Array(original[Int(1.4 * rate)...]))
    }

    @Test func aCueBeforeTheMicOpenedIsHandledAtTheEdge() {
        var recording = [Float](repeating: 0.01, count: 4_000)
        StartCue.remove(from: &recording, cueOffset: -0.2, sampleRate: rate)
        #expect(recording.count == 4_000)
        #expect(recording.allSatisfy { $0.isFinite })
    }

    @Test func soundsRenderAsPlayableWAV() {
        let data = DictationSounds.wav(StartCue.render(sampleRate: 44_100), sampleRate: 44_100)
        #expect(data.prefix(4) == Data("RIFF".utf8))
        #expect(data.count > 44 + 44_100 * 2 / 10)
    }
}
