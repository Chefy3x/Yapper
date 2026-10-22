import Testing
import Foundation

// Voice In's sounds, and taking the start sound back out of the recording it plays into.
struct StartCueTests {
    private let rate = 16_000.0

    private func energy(_ x: ArraySlice<Float>) -> Double { x.reduce(0) { $0 + Double($1 * $1) } }

    /// A crude voiced sound above 600 Hz: the 5th to 28th harmonics of a 140 Hz voice, falling off
    /// with frequency. That band carries the vowels' 2nd formant and the consonants, which is what
    /// the speech model reads; the filters only touch what's below and around the start sound.
    private func voice(seconds: Double) -> [Float] {
        (0..<Int(seconds * rate)).map { i in
            let t = Double(i) / rate
            var v = 0.0
            for h in 5...28 { v += sin(2 * .pi * 140 * Double(h) * t + Double(h)) / Double(h) }
            return Float(v * 0.05)
        }
    }

    /// A start sound as the mic hears it: mono, at the capture rate.
    private func startAsHeard(_ sound: DictationSound = .start) -> [Float] {
        let s = sound.render(sampleRate: rate)
        return zip(s.left, s.right).map { ($0 + $1) / 2 }
    }

    @Test func theStartSoundIsMostlyRemovedFromTheRecording() {
        let cue = startAsHeard()
        var recording = [Float](repeating: 0, count: Int(3 * rate))
        let at = Int(0.5 * rate)
        for (i, s) in cue.enumerated() where at + i < recording.count { recording[at + i] += s }
        // The part that matters: the thud and the note, before the hall's tail.
        let window = at..<(at + Int(StartCue.chime.duration * rate))
        let before = energy(recording[window])
        StartCue.chime.remove(from: &recording, cueOffset: 0.5, sampleRate: rate)
        let after = energy(recording[window])
        // At least 20 dB quieter; what's left sits far under speech.
        #expect(after < before / 100)
    }

    @Test func theMouthsPopIsTakenWellDown() {
        let cue = startAsHeard(.mouthOpen)
        var recording = [Float](repeating: 0, count: Int(3 * rate))
        let at = Int(0.5 * rate)
        for (i, s) in cue.enumerated() where at + i < recording.count { recording[at + i] += s }
        let window = at..<(at + Int(StartCue.mouth.duration * rate))
        let before = energy(recording[window])
        DictationSound.mouthOpen.cue.remove(from: &recording, cueOffset: 0.5, sampleRate: rate)
        // A gliding pop can't be notched as clean as the chime's held note: about 9 dB, the
        // breath at its front included (the pop's body alone goes about 15 dB down).
        #expect(energy(recording[window]) < before / 6)
    }

    @Test func eachStartSoundSaysHowToTakeItOut() {
        #expect(DictationSound.start(mouth: false).cue.highpass == StartCue.chime.highpass)
        #expect(DictationSound.start(mouth: true).cue.notchFrequencies == StartCue.mouth.notchFrequencies)
    }

    @Test func speechAroundTheCueKeepsItsEnergy() {
        let original = voice(seconds: 2.5)
        var filtered = original
        StartCue.chime.remove(from: &filtered, cueOffset: 0.5, sampleRate: rate)
        let a = energy(original[...]), b = energy(filtered[...])
        #expect(b / a > 0.95)
        // And outside the window not one sample changes.
        let end = Int((0.5 + StartCue.chime.duration + 0.56) * rate)
        #expect(Array(filtered[end...]) == Array(original[end...]))
        // The mouth's notches cost the voice a little more, over a much shorter window.
        var mouthed = original
        StartCue.mouth.remove(from: &mouthed, cueOffset: 0.5, sampleRate: rate)
        #expect(energy(mouthed[...]) / a > 0.95)
    }

    @Test func aCueBeforeTheMicOpenedIsHandledAtTheEdge() {
        var recording = [Float](repeating: 0.01, count: 4_000)
        StartCue.chime.remove(from: &recording, cueOffset: -0.2, sampleRate: rate)
        #expect(recording.count == 4_000)
        #expect(recording.allSatisfy { $0.isFinite })
    }

    @Test func eachSoundIsShortStereoAndAtItsLevel() {
        for sound in DictationSound.allCases where !sound.isMouth {
            let s = sound.render()
            let seconds = Double(s.count) / SoundSynth.sampleRate
            #expect(seconds > 0.3 && seconds <= 1.6)
            let peak = zip(s.left, s.right).map { max(abs($0), abs($1)) }.max() ?? 0
            #expect(abs(peak - sound.peak) < 0.001)
            // The hall makes it wide: left and right differ in the tail.
            let tail = Int(0.4 * SoundSynth.sampleRate)..<Int(0.8 * SoundSynth.sampleRate)
            #expect(s.left[tail] != s.right[tail])
            // And it ends in silence, not a click.
            #expect(abs(s.left.last ?? 1) < 1e-4 && abs(s.right.last ?? 1) < 1e-4)
        }
    }

    @Test func theMouthsSoundsAreDryShortAndAtTheirLevel() {
        for sound in DictationSound.allCases where sound.isMouth {
            let s = sound.render()
            #expect(Double(s.count) / SoundSynth.sampleRate <= 0.8)
            let peak = zip(s.left, s.right).map { max(abs($0), abs($1)) }.max() ?? 0
            #expect(abs(peak - sound.peak) < 0.001)
            #expect(s.left == s.right)                 // close and centred, no hall
            #expect(abs(s.left.last ?? 1) < 1e-4)
        }
    }

    @Test func theGrinsPopOutLandsAsTheMouthDropsAway() {
        // The reaction holds 0.7 s, then the pill closes.
        let s = DictationSound.mouthGrin.render()
        let r = SoundSynth.sampleRate
        let late = s.left[Int(0.66 * r)...].map(abs).max() ?? 0
        let quiet = s.left[Int(0.55 * r)..<Int(0.66 * r)].map(abs).max() ?? 1
        #expect(late > 0.1 && quiet < 0.01)
    }

    @Test func theHallSitsFarUnderTheNotes() {
        let s = DictationSound.start.render()
        func rms(_ x: ArraySlice<Float>) -> Double { (energy(x) / Double(x.count)).squareRoot() }
        let r = SoundSynth.sampleRate
        let head = rms(s.left[0..<Int(0.05 * r)])
        let tail = rms(s.left[Int(0.6 * r)..<Int(0.9 * r)])
        #expect(20 * log10(tail / head) < -25)
    }

    @Test func rendersTheSameEveryTime() {
        #expect(DictationSound.done.render() == DictationSound.done.render())
        #expect(DictationSound.mouthGrimace.render() == DictationSound.mouthGrimace.render())
    }

    @Test func soundsWriteAsPlayableStereoWAV() {
        let data = DictationSounds.wav(DictationSound.failed.render(), sampleRate: SoundSynth.sampleRate)
        #expect(data.prefix(4) == Data("RIFF".utf8))
        #expect(data[22] == 2)   // channels
        #expect(data.count > 44 + 44_100 * 4 / 10)
    }
}
