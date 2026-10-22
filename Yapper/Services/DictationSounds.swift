import AVFoundation

/// Voice In's three sounds, synthesised here rather than shipped as files, so Yapper knows
/// exactly what it played and where its energy sits.
///
/// - start: a soft low thud, then one rounded C4, into a short shimmering hall.
/// - done: two rounded notes rising, C4 then G4, in the same hall.
/// - failed: the thud on its own.
///
/// Shaped by ear against the references the user picked: Superwhisper Classic's thud and the
/// polish of Apple's Rebound, whose quality is short, clean notes into a quiet, wide, slowly
/// moving hall roughly 32 dB under them.
///
/// The Loud Mouth opens to the same start sound, but has its own done and failed sounds,
/// recordings bundled as WAVs and played as they are: single syllables of one low chuckle (CC0,
/// freesound.org, remarknl "Evil_chuckle", take 3), warmed, cut under 175 Hz, in a short dark
/// room, picked and treated by ear with the user.
/// - mouthGrin: its first syllable, as the grin starts.
/// - mouthGrimace: its last, as the mouth grimaces at a turn that typed nothing.
enum DictationSound: CaseIterable, Sendable {
    case start, done, failed
    case mouthGrin, mouthGrimace

    /// The done and failed sounds with the Loud Mouth on show, or with the bars.
    static func done(mouth: Bool) -> DictationSound { mouth ? .mouthGrin : .done }
    static func failed(mouth: Bool) -> DictationSound { mouth ? .mouthGrimace : .failed }

    /// The bundled WAV a recorded sound plays from; nil for the synthesised chimes.
    var recording: String? {
        switch self {
        case .mouthGrin: "mouth-grin"
        case .mouthGrimace: "mouth-grimace"
        case .start, .done, .failed: nil
        }
    }

    var isMouth: Bool { recording != nil }

    /// Peak level of a synthesised sound, linear. The start leads; the others sit a little under it.
    var peak: Float { self == .start ? 0.32 : 0.27 }

    /// The sound as WAV data, ready for a player: the recording from `bundle`, or rendered.
    func wav(in bundle: Bundle = .main) -> Data? {
        guard let recording else { return DictationSounds.wav(render(), sampleRate: SoundSynth.sampleRate) }
        return bundle.url(forResource: recording, withExtension: "wav").flatMap { try? Data(contentsOf: $0) }
    }

    /// Synthesises a chime. The mouth's sounds are recordings (see `wav(in:)`) and render empty.
    func render(sampleRate r: Double = SoundSynth.sampleRate) -> SoundSynth.Stereo {
        let c4 = 261.63, g4 = 392.0
        let events: [SoundSynth.Event]
        let wetDB: Double
        switch self {
        case .mouthGrin, .mouthGrimace:
            return SoundSynth.Stereo(left: [], right: [])
        case .start:
            events = [.init(start: 0, samples: SoundSynth.thud(sampleRate: r), gain: 0.55),
                      .init(start: 0.11, samples: SoundSynth.roundedNote(c4, sampleRate: r), gain: 0.7)]
            wetDB = -32
        case .done:
            events = [.init(start: 0, samples: SoundSynth.roundedNote(c4, sampleRate: r), gain: 0.6),
                      .init(start: 0.08, samples: SoundSynth.roundedNote(g4, sampleRate: r), gain: 0.6)]
            wetDB = -34
        case .failed:
            events = [.init(start: 0, samples: SoundSynth.thud(sampleRate: r), gain: 0.55)]
            wetDB = -30
        }
        return SoundSynth.finish(SoundSynth.mix(events, wetDB: wetDB, sampleRate: r), peak: peak, sampleRate: r)
    }
}

/// The pieces the sounds are made of.
enum SoundSynth {
    static let sampleRate = 44_100.0

    struct Event { let start: Double; let samples: [Float]; let gain: Float }

    struct Stereo: Equatable {
        var left: [Float]
        var right: [Float]
        var count: Int { left.count }
    }

    /// Raised-cosine fade-in over `attack` seconds.
    static func fadeIn(_ t: Double, _ attack: Double) -> Double {
        t < attack ? 0.5 - 0.5 * cos(.pi * t / attack) : 1
    }

    /// A soft low thud: the pitch drops from 200 Hz to 82 Hz in a few milliseconds the way a
    /// drum's does, holds briefly, then dies fast; a little saturation lets small speakers hear it.
    static func thud(sampleRate r: Double) -> [Float] {
        let drive = 1.3, norm = tanh(drive)
        var phase = 0.0
        return (0..<Int(0.2 * r)).map { i in
            let t = Double(i) / r
            phase += 2 * .pi * (82 + (200 - 82) * exp(-t / 0.004)) / r
            let env = fadeIn(t, 0.010) * (t < 0.035 ? 1 : exp(-(t - 0.035) / 0.009))
            return Float(tanh(drive * sin(phase) * env) / norm)
        }
    }

    /// A pure note that swells in over 10 ms and rings away, no pluck at the front.
    static func roundedNote(_ f: Double, sampleRate r: Double) -> [Float] {
        (0..<Int(0.35 * r)).map { i in
            let t = Double(i) / r
            return Float(sin(2 * .pi * f * t) * fadeIn(t, 0.010) * exp(-t / 0.035))
        }
    }

    /// One-pole low-pass, the gentle kind: for keeping the hall's input dark and clean.
    static func lowpass(_ x: [Float], cutoff: Double, sampleRate r: Double) -> [Float] {
        let a = Float(exp(-2 * .pi * cutoff / r))
        var s: Float = 0
        return x.map { v in s = (1 - a) * v + a * s; return s }
    }

    static func highpass(_ x: [Float], cutoff: Double, sampleRate r: Double) -> [Float] {
        zip(x, lowpass(x, cutoff: cutoff, sampleRate: r)).map { $0 - $1 }
    }

    /// The hall: eight delay lines feeding back through a Householder mix, each line's length
    /// drifting slowly (the shimmer), the feedback damped above 5.5 kHz, read out by two
    /// different taps so the tail is wide. `rt` is the time it takes to fall 60 dB.
    static func hall(_ mono: [Float], rt: Double = 1.5, predelay: Double = 0.022, modulation: Double = 6,
                     damping: Double = 5_500, sampleRate r: Double) -> Stereo {
        let lengths: [Double] = [1031, 1327, 1523, 1801, 2053, 2389, 2711, 3089]
        let n = lengths.count, maxLength = Int(lengths.max()!) + 64
        let gains = lengths.map { pow(10, -3 * $0 / r / rt) }
        let rates = (0..<n).map { 0.31 + (0.83 - 0.31) * Double($0) / Double(n - 1) }
        let phases = (0..<n).map { 2 * Double.pi * Double($0) / Double(n) }
        let tapL: [Double] = [1, -1, 1, -1, 1, 1, -1, -1], tapR: [Double] = [1, 1, -1, -1, 1, -1, 1, -1]
        let scale = 1 / Double(n).squareRoot()
        let a = exp(-2 * .pi * damping / r)
        let pre = Int(predelay * r)
        let total = mono.count + Int(rt * 1.1 * r) + pre

        var buffers = [[Double]](repeating: [Double](repeating: 0, count: maxLength), count: n)
        var damped = [Double](repeating: 0, count: n)
        var y = [Double](repeating: 0, count: n)
        var write = 0
        var out = Stereo(left: [Float](repeating: 0, count: total), right: [Float](repeating: 0, count: total))
        for i in 0..<total {
            let input = i >= pre && i - pre < mono.count ? Double(mono[i - pre]) : 0
            var sum = 0.0
            for k in 0..<n {
                let delay = lengths[k] + modulation * sin(2 * .pi * rates[k] * Double(i) / r + phases[k])
                var read = Double(write) - delay
                read -= Double(maxLength) * (read / Double(maxLength)).rounded(.down)
                let i0 = Int(read), frac = read - Double(i0)
                let v = buffers[k][i0] * (1 - frac) + buffers[k][(i0 + 1) % maxLength] * frac
                damped[k] = (1 - a) * v + a * damped[k]
                y[k] = damped[k] * gains[k]
                sum += y[k]
            }
            var l = 0.0, rr = 0.0
            for k in 0..<n {
                buffers[k][write] = y[k] - 2 / Double(n) * sum + scale * input
                l += tapL[k] * y[k]; rr += tapR[k] * y[k]
            }
            out.left[i] = Float(l * scale); out.right[i] = Float(rr * scale)
            write = (write + 1) % maxLength
        }
        return out
    }

    /// Lays the parts out dry in the centre, and sends them (darkened, with the rumble taken off)
    /// into the hall. The tail is placed `wetDB` under the dry sound: its level 0.2–0.5 s in,
    /// against the first 50 ms. The whole is cut at 1.6 s with a 0.4 s fade.
    static func mix(_ events: [Event], wetDB: Double, rt: Double = 1.5, sampleRate r: Double) -> Stereo {
        let length = events.map { Int($0.start * r) + $0.samples.count }.max() ?? 0
        var dry = [Float](repeating: 0, count: length)
        for e in events {
            let first = Int(e.start * r)
            for (i, s) in e.samples.enumerated() { dry[first + i] += s * e.gain }
        }
        let send = highpass(lowpass(dry, cutoff: 6_000, sampleRate: r), cutoff: 220, sampleRate: r)
        let wet = hall(send, rt: rt, sampleRate: r)
        func meanSquare(_ x: ArraySlice<Float>) -> Double {
            x.isEmpty ? 0 : x.reduce(0) { $0 + Double($1 * $1) } / Double(x.count)
        }
        let ref = meanSquare(dry.prefix(Int(0.05 * r))).squareRoot() + 1e-12
        let window = Int(0.2 * r)..<min(wet.count, Int(0.5 * r))
        let tail = ((meanSquare(wet.left[window]) + meanSquare(wet.right[window])) / 2).squareRoot() + 1e-12
        let g = Float(ref / tail * pow(10, wetDB / 20))
        var out = Stereo(left: wet.left.map { $0 * g }, right: wet.right.map { $0 * g })
        for i in 0..<dry.count { out.left[i] += dry[i]; out.right[i] += dry[i] }

        let cut = Int(1.6 * r)
        if cut < out.count {
            out.left.removeLast(out.left.count - cut); out.right.removeLast(out.right.count - cut)
            let fade = Int(0.4 * r)
            for j in 0..<fade {
                let w = Float(fade - 1 - j) / Float(fade - 1)
                out.left[cut - fade + j] *= w; out.right[cut - fade + j] *= w
            }
        }
        return out
    }

    /// Trims the silent end, scales to `peak`, and fades the last 50 ms.
    static func finish(_ s: Stereo, peak: Float, sampleRate r: Double) -> Stereo {
        let loudest = zip(s.left, s.right).map { max(abs($0), abs($1)) }
        guard let last = loudest.lastIndex(where: { $0 > 3e-5 }), let top = loudest.max(), top > 0 else { return s }
        let g = peak / top
        var out = Stereo(left: s.left[...last].map { $0 * g }, right: s.right[...last].map { $0 * g })
        let fade = min(Int(0.05 * r), out.count)
        for j in 0..<fade {
            let w = Float(fade - 1 - j) / Float(max(1, fade - 1))
            out.left[out.count - fade + j] *= w; out.right[out.count - fade + j] *= w
        }
        return out
    }
}

/// The start sound plays into an open mic (it opens at key-down so the first word isn't lost),
/// so it always lands in the audio. This takes it back out.
struct StartCue: Sendable {
    /// When the dry part of the sound ends, from its start.
    let duration: Double
    /// How long it rings on after that.
    let tail: Double
    /// Below this goes, steeply.
    let highpass: Double?
    /// Each notched twice.
    let notchFrequencies: [Double]
    let notchQ: Double

    /// The chime: the thud, then the C4 starting at 0.11 s and ringing out, with the hall going on
    /// under it about 32 dB down. The thud lives under 200 Hz, so a steep high-pass takes it. The
    /// C4 is a pure tone, so there's no overtone to chase; a notch an octave up would only cost
    /// the voice.
    static let chime = StartCue(duration: 0.45, tail: 0.55, highpass: 230, notchFrequencies: [261.63], notchQ: 4)

    func filters(sampleRate: Double) -> [Biquad] {
        (highpass.map { Array(repeating: Biquad.highpass(frequency: $0, q: 0.7071, sampleRate: sampleRate), count: 3) } ?? [])
            + notchFrequencies.flatMap { f in
                Array(repeating: Biquad.notch(frequency: f, q: notchQ, sampleRate: sampleRate), count: 2)
            }
    }

    /// Takes the start sound out of a recording that heard it. `cueOffset` is when it started,
    /// in seconds from the first sample. The window runs from a little before (the clocks are only
    /// roughly aligned) to well after (the sound rings on). Outside it, not one sample changes.
    func remove(from samples: inout [Float], cueOffset: TimeInterval, sampleRate: Double) {
        let lead = 0.15
        let start = max(0, Int((cueOffset - lead) * sampleRate))
        let end = min(samples.count, Int((cueOffset + duration + tail) * sampleRate))
        guard end - start > 32 else { return }
        var segment = Array(samples[start..<end])
        for var stage in filters(sampleRate: sampleRate) { stage.process(&segment) }
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
}

/// One RBJ-cookbook biquad section, direct form I.
struct Biquad {
    var b0, b1, b2, a1, a2: Float
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    static func highpass(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q), c = cos(w0)
        let a0 = 1 + alpha
        return Biquad(b0: Float((1 + c) / 2 / a0), b1: Float(-(1 + c) / a0), b2: Float((1 + c) / 2 / a0),
                      a1: Float(-2 * c / a0), a2: Float((1 - alpha) / a0))
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

/// Plays the sounds. They're rendered (or read from the bundle) once, off the main thread, as
/// soon as Yapper starts, into ready players, so playing one costs the turn nothing.
@MainActor
final class DictationSounds {
    private var players: [DictationSound: AVAudioPlayer] = [:]
    /// Bumped by every start and stop of the start sound, so a late fade-out can't cut a new one.
    private var startGeneration = 0

    init() {
        Task { [weak self] in
            let rendered = await Task.detached(priority: .utility) {
                DictationSound.allCases.compactMap { sound in sound.wav().map { (sound, $0) } }
            }.value
            for (sound, data) in rendered {
                let player = try? AVAudioPlayer(data: data)
                player?.prepareToPlay()
                self?.players[sound] = player
            }
        }
    }

    /// Returns when the sound started and how to take it back out, for `StartCue.remove`. Nil if
    /// it couldn't play (or the sounds are still being rendered in the first moment after launch).
    func playStart() -> (at: Date, cue: StartCue)? {
        // A grin or grimace still sounding belongs to the last turn.
        fadeOut(.mouthGrin)
        fadeOut(.mouthGrimace)
        guard let start = players[.start] else { return nil }
        startGeneration += 1
        start.volume = 1
        start.currentTime = 0
        return start.play() ? (Date(), .chime) : nil
    }

    /// Fades the start sound out over a few milliseconds (a hard stop clicks).
    func stopStart() {
        guard let start = players[.start], start.isPlaying else { return }
        startGeneration += 1
        let generation = startGeneration
        start.setVolume(0, fadeDuration: 0.04)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            // A press that came in meanwhile has restarted it; leave that one alone.
            guard let self, self.startGeneration == generation else { return }
            start.stop()
            start.volume = 1
        }
    }

    func playDone(mouth: Bool) { play(.done(mouth: mouth)) }
    func playFailed(mouth: Bool) { play(.failed(mouth: mouth)) }

    private func play(_ sound: DictationSound) {
        guard let player = players[sound] else { return }
        player.volume = 1
        player.currentTime = 0
        player.play()
    }

    private func fadeOut(_ sound: DictationSound) {
        guard let player = players[sound], player.isPlaying else { return }
        player.setVolume(0, fadeDuration: 0.04)
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            // Played again meanwhile: it's back up, so leave it.
            guard player.volume == 0 else { return }
            player.stop()
        }
    }

    /// 16-bit stereo PCM WAV in memory.
    nonisolated static func wav(_ sound: SoundSynth.Stereo, sampleRate: Double) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func sample(_ s: Float) -> Int16 { Int16(max(-1, min(1, s)) * Float(Int16.max)) }
        let bytes = UInt32(sound.count * 4)
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36) + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(2))
        put(UInt32(sampleRate)); put(UInt32(sampleRate) * 4); put(UInt16(4)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(bytes)
        for i in 0..<sound.count { put(sample(sound.left[i])); put(sample(sound.right[i])) }
        return data
    }
}
