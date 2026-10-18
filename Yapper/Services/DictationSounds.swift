import AVFoundation

/// The start sound: two short sine notes, rising. Synthesised here rather than shipped as a file,
/// so Yapper knows its exact frequencies and can notch it back out of a recording it played
/// into. The mic is open by the time a hold is recognised (it opens at key-down so the first
/// word isn't lost), so the sound always lands in the audio.
enum StartCue {
    struct Note: Sendable { let frequency: Double; let start: Double; let length: Double }

    /// E6 then B6. High enough to sit above the body of speech, low enough to stay pleasant.
    /// Long enough and soft-edged enough that each note's energy stays in a narrow band.
    static let notes: [Note] = [Note(frequency: 1318.51, start: 0, length: 0.12),
                                Note(frequency: 1975.53, start: 0.08, length: 0.16)]
    static var duration: Double { notes.map { $0.start + $0.length }.max() ?? 0 }

    /// Every frequency the cue puts into a room: the notes and the second harmonic a small
    /// speaker adds to them.
    static var notchFrequencies: [Double] { notes.flatMap { [$0.frequency, $0.frequency * 2] } }

    /// Takes the cue out of a recording that heard it. `cueOffset` is when the cue started,
    /// in seconds from the first sample. The window runs from a little before (output latency
    /// is never negative, but the clocks are only roughly aligned) to well after (the room rings).
    /// Each notch runs twice: about 35 dB off the cue, while a voice keeps 96% of its energy.
    static func remove(from samples: inout [Float], cueOffset: TimeInterval, sampleRate: Double) {
        let lead = 0.15, tail = 0.45
        let start = max(0, Int((cueOffset - lead) * sampleRate))
        let end = min(samples.count, Int((cueOffset + duration + tail) * sampleRate))
        guard end - start > 32 else { return }
        var segment = Array(samples[start..<end])
        for f in notchFrequencies where f < sampleRate / 2 - 200 {
            for _ in 0..<2 {
                var notch = Biquad.notch(frequency: f, q: 8, sampleRate: sampleRate)
                notch.process(&segment)
            }
        }
        // Fade between the original and the filtered audio at both edges, so the filters
        // starting and stopping never click.
        let fade = min(Int(0.01 * sampleRate), segment.count / 2)
        for i in 0..<segment.count {
            let original = samples[start + i]
            let w: Float
            if i < fade { w = Float(i) / Float(fade) }
            else if i >= segment.count - fade { w = Float(segment.count - 1 - i) / Float(fade) }
            else { w = 1 }
            samples[start + i] = original + (segment[i] - original) * w
        }
    }

    /// The cue as samples: each note with a 20 ms raised-cosine attack and an exponential decay,
    /// so its energy stays in a narrow band the notches can reach.
    static func render(notes: [Note] = notes, sampleRate: Double, gain: Float = 0.5) -> [Float] {
        let total = Int(((notes.map { $0.start + $0.length }.max() ?? 0) + 0.02) * sampleRate)
        var out = [Float](repeating: 0, count: total)
        for note in notes {
            let first = Int(note.start * sampleRate)
            let count = Int(note.length * sampleRate)
            let attack = Int(0.02 * sampleRate)
            for i in 0..<count where first + i < total {
                let t = Double(i) / sampleRate
                let env = (i < attack ? 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(attack)) : 1)
                    * exp(-t / (note.length * 0.5))
                    * (i > count - attack ? Double(count - i) / Double(attack) : 1)
                out[first + i] += Float(sin(2 * .pi * note.frequency * t) * env) * gain
            }
        }
        return out
    }
}

/// One RBJ-cookbook biquad section, direct form I.
struct Biquad {
    var b0, b1, b2, a1, a2: Float
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    static func notch(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        return Biquad(b0: Float(1 / a0), b1: Float(-2 * cos(w0) / a0), b2: Float(1 / a0),
                      a1: Float(-2 * cos(w0) / a0), a2: Float((1 - alpha) / a0))
    }

    mutating func process(_ samples: inout [Float]) {
        for i in samples.indices {
            let x = samples[i]
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            samples[i] = y
        }
    }
}

/// Plays the start and done sounds. Both are rendered once, at launch, into ready players, so
/// starting one costs the turn nothing.
@MainActor
final class DictationSounds {
    private let start: AVAudioPlayer?
    private let done: AVAudioPlayer?
    private let failed: AVAudioPlayer?

    init() {
        let rate = 44_100.0
        start = Self.player(StartCue.render(sampleRate: rate, gain: 0.32), rate: rate)
        // Done: the same two notes falling, softer and shorter. The mic is closed by then.
        done = Self.player(StartCue.render(notes: [.init(frequency: 1975.53, start: 0, length: 0.06),
                                                   .init(frequency: 1318.51, start: 0.045, length: 0.09)],
                                           sampleRate: rate, gain: 0.2), rate: rate)
        failed = Self.player(StartCue.render(notes: [.init(frequency: 660, start: 0, length: 0.09),
                                                     .init(frequency: 622.25, start: 0.08, length: 0.12)],
                                             sampleRate: rate, gain: 0.22), rate: rate)
    }

    /// Returns when the sound started, for `StartCue.remove`.
    func playStart() -> Date? {
        guard let start else { return nil }
        start.currentTime = 0
        return start.play() ? Date() : nil
    }

    func playDone() {
        done?.currentTime = 0
        done?.play()
    }

    func playFailed() {
        failed?.currentTime = 0
        failed?.play()
    }

    private static func player(_ samples: [Float], rate: Double) -> AVAudioPlayer? {
        let player = try? AVAudioPlayer(data: wav(samples, sampleRate: rate))
        player?.prepareToPlay()
        return player
    }

    /// 16-bit mono PCM WAV in memory.
    nonisolated static func wav(_ samples: [Float], sampleRate: Double) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36) + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(sampleRate)); put(UInt32(sampleRate) * 2); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(bytes)
        for s in samples { put(Int16(max(-1, min(1, s)) * Float(Int16.max))) }
        return data
    }
}
