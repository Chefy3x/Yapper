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
/// The Loud Mouth has its own three, dry and close, made of mouth noises timed to its animation:
/// - mouthOpen: the lips parting as it springs up, the pop's pitch rising as the mouth widens.
/// - mouthGrin: a pleased "mm-hm", then at 0.7 s, as it drops back into the pill, the lips
///   parting off the grin, the pop's pitch falling.
/// - mouthGrimace: a tut and a let-down "hm", then the same pop out.
enum DictationSound: CaseIterable, Sendable {
    case start, done, failed
    case mouthOpen, mouthGrin, mouthGrimace

    /// The sounds to play with the Loud Mouth on show, or with the bars.
    static func start(mouth: Bool) -> DictationSound { mouth ? .mouthOpen : .start }
    static func done(mouth: Bool) -> DictationSound { mouth ? .mouthGrin : .done }
    static func failed(mouth: Bool) -> DictationSound { mouth ? .mouthGrimace : .failed }

    var isMouth: Bool { [.mouthOpen, .mouthGrin, .mouthGrimace].contains(self) }

    /// Peak level, linear. The start leads; the others sit a little under it.
    var peak: Float { self == .start || self == .mouthOpen ? 0.32 : 0.27 }

    /// What it takes to get this sound back out of a recording it played into.
    var cue: StartCue { isMouth ? .mouth : .chime }

    func render(sampleRate r: Double = SoundSynth.sampleRate) -> SoundSynth.Stereo {
        let c4 = 261.63, g4 = 392.0
        let events: [SoundSynth.Event]
        let wetDB: Double
        switch self {
        case .mouthOpen, .mouthGrin, .mouthGrimace:
            return SoundSynth.finish(SoundSynth.dry(mouthEvents(sampleRate: r), sampleRate: r), peak: peak, sampleRate: r)
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

    /// The mouth's parts in time. The pop out lands at 0.7 s, when the reaction ends and the
    /// mouth drops back into the pill.
    private func mouthEvents(sampleRate r: Double) -> [SoundSynth.Event] {
        let out = 0.68
        switch self {
        case .mouthOpen:
            return [.init(start: 0.03, samples: SoundSynth.lipPop(from: 330, to: 560, sampleRate: r, seed: 1), gain: 1)]
        case .mouthGrin:
            return [.init(start: 0.02, samples: SoundSynth.mmHm(sampleRate: r), gain: 1),
                    .init(start: out, samples: SoundSynth.lipPop(from: 520, to: 300, sampleRate: r, seed: 2), gain: 0.8)]
        case .mouthGrimace:
            return [.init(start: 0, samples: SoundSynth.tsk(sampleRate: r, seed: 3), gain: 0.9),
                    .init(start: 0.14, samples: SoundSynth.letDownHm(sampleRate: r), gain: 0.8),
                    .init(start: out, samples: SoundSynth.lipPop(from: 520, to: 300, sampleRate: r, seed: 4), gain: 0.8)]
        default:
            return []
        }
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

    // MARK: The mouth's pieces

    /// Lays the parts out dry in the centre, with no hall: a mouth is close.
    static func dry(_ events: [Event], sampleRate r: Double) -> Stereo {
        let length = events.map { Int($0.start * r) + $0.samples.count }.max() ?? 0
        var mono = [Float](repeating: 0, count: length)
        for e in events {
            let first = Int(e.start * r)
            for (i, s) in e.samples.enumerated() { mono[first + i] += s * e.gain }
        }
        return Stereo(left: mono, right: mono)
    }

    /// Noise that comes out the same on every render, so a sound always does.
    struct Noise {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(Int64(bitPattern: state) >> 11) / Double(1 << 52)
        }
    }

    /// A two-pole resonance rung by `x`, its frequency free to move; unity gain at its peak.
    static func resonate(_ x: [Double], bandwidth: Double, sampleRate r: Double,
                         frequency: (Double) -> Double) -> [Double] {
        let radius = exp(-.pi * bandwidth / r)
        var y1 = 0.0, y2 = 0.0
        return x.enumerated().map { i, v in
            let theta = 2 * .pi * frequency(Double(i) / r) / r
            let g = (1 - radius) * (1 - 2 * radius * cos(2 * theta) + radius * radius).squareRoot()
            let y = g * v + 2 * radius * cos(theta) * y1 - radius * radius * y2
            y2 = y1; y1 = y
            return y
        }
    }

    /// Lips coming apart: a push of air, then the mouth's own resonance ringing for a moment, its
    /// pitch gliding from `from` to `to` as the mouth's shape changes (up as it opens wide, down as
    /// it lets go of a grin).
    static func lipPop(from f0: Double, to f1: Double, sampleRate r: Double, seed: UInt64) -> [Float] {
        var noise = Noise(state: seed)
        var x = (0..<Int(0.09 * r)).map { i -> Double in
            let t = Double(i) / r
            return noise.next() * fadeIn(t, 0.0005) * exp(-t / 0.003) * 0.4
        }
        x[0] += 1
        let body = resonate(x, bandwidth: 32, sampleRate: r) { t in f1 + (f0 - f1) * exp(-t / 0.015) }
        let air = resonate(x, bandwidth: 1_200, sampleRate: r) { _ in 1_800 }
        let popped = (0..<x.count).map { i -> Double in
            let t = Double(i) / r
            let end = t < 0.055 ? 1 : exp(-(t - 0.055) / 0.006)
            return (body[i] + 0.06 * air[i]) * end
        }
        let level = popped.map(abs).max() ?? 1
        return popped.map { Float($0 / level) }
    }

    /// A hum through closed lips, its pitch following `pitch`: a voice's buzz (harmonics falling
    /// away 9 dB an octave, a slight wobble) through the low murmur of an [m], with a faint trace of
    /// the formant above it. `envelope` shapes the loudness.
    static func hum(seconds: Double, pitch: (Double) -> Double, envelope: (Double) -> Double,
                    sampleRate r: Double) -> [Double] {
        var phase = 0.0
        let source = (0..<Int(seconds * r)).map { i -> Double in
            let t = Double(i) / r
            let f = pitch(t) * (1 + 0.006 * sin(2 * .pi * 5.5 * t))
            phase += 2 * .pi * f / r
            var v = 0.0
            for k in 1...max(1, Int(3_500 / f)) { v += sin(Double(k) * phase) / pow(Double(k), 1.5) }
            return v * envelope(t)
        }
        let murmur = resonate(source, bandwidth: 80, sampleRate: r) { _ in 270 }
        let upper = resonate(source, bandwidth: 300, sampleRate: r) { _ in 2_300 }
        return zip(murmur, upper).map { $0 + 0.08 * $1 }
    }

    /// A syllable's loudness: in over `attack`, steady, out over `release`.
    static func syllable(_ t: Double, length: Double, attack: Double, release: Double) -> Double {
        guard t >= 0, t < length else { return 0 }
        let fall = length - t < release ? 0.5 - 0.5 * cos(.pi * (length - t) / release) : 1
        return fadeIn(t, attack) * fall
    }

    /// "Mm-hm!": a short hum, a breath, then a longer one rising at its end, the way a yes does.
    static func mmHm(sampleRate r: Double) -> [Float] {
        let first = 0.12, gap = 0.05, second = 0.24
        let humming = hum(seconds: first + gap + second, pitch: { t in
            t < first + gap ? 200 + 10 * t / first : 205 + 65 * (1 - exp(-(t - first - gap) / 0.07))
        }, envelope: { t in
            syllable(t, length: first, attack: 0.02, release: 0.035)
                + 1.15 * syllable(t - first - gap, length: second, attack: 0.015, release: 0.08)
        }, sampleRate: r)
        // The [h] between them: breath through the nose, quiet and dark.
        var noise = Noise(state: 7)
        let breath = lowpass((0..<humming.count).map { i in
            Float(noise.next() * syllable(Double(i) / r - first + 0.01, length: gap + 0.02, attack: 0.015, release: 0.02))
        }, cutoff: 1_500, sampleRate: r)
        let level = humming.map(abs).max() ?? 1
        return zip(humming, breath).map { Float($0 / level) + 0.06 * $1 }
    }

    /// A let-down "hm", falling.
    static func letDownHm(sampleRate r: Double) -> [Float] {
        let length = 0.2
        let humming = hum(seconds: length, pitch: { t in 185 - 45 * t / length },
                          envelope: { t in syllable(t, length: length, attack: 0.02, release: 0.09) }, sampleRate: r)
        let level = humming.map(abs).max() ?? 1
        return humming.map { Float($0 / level) }
    }

    /// The tongue snapping off the roof of the mouth: a sharp crack, rung bright and brief.
    static func tsk(sampleRate r: Double, seed: UInt64) -> [Float] {
        var noise = Noise(state: seed)
        var x = (0..<Int(0.03 * r)).map { i in noise.next() * exp(-Double(i) / r / 0.0012) * 0.5 }
        x[0] += 1
        let crack = resonate(x, bandwidth: 450, sampleRate: r) { _ in 3_000 }
        let bright = resonate(x, bandwidth: 800, sampleRate: r) { _ in 4_600 }
        let hollow = resonate(x, bandwidth: 250, sampleRate: r) { _ in 1_300 }
        let mixed = (0..<x.count).map { crack[$0] + 0.5 * bright[$0] + 0.35 * hollow[$0] }
        let level = mixed.map(abs).max() ?? 1
        return mixed.map { Float($0 / level) }
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

    /// The Loud Mouth's lips parting: dry and over by 0.1 s, its body one resonance gliding from
    /// 330 to 560 Hz but ringing mostly on the way, which three notches take about 15 dB down. A
    /// gliding pop can't be notched as clean as a held note, but it's over before you speak, and
    /// the breath at its front is too short and quiet for the speech model to make anything of.
    static let mouth = StartCue(duration: 0.1, tail: 0.06, highpass: nil,
                                notchFrequencies: [340, 420, 500], notchQ: 2.4)

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

/// Plays the sounds. They're rendered once, off the main thread, as soon as Yapper starts,
/// into ready players, so playing one costs the turn nothing.
@MainActor
final class DictationSounds {
    private var players: [DictationSound: AVAudioPlayer] = [:]
    /// Bumped by every start and stop of the start sound, so a late fade-out can't cut a new one.
    private var startGeneration = 0
    /// The start sound last played: the chime or the mouth's.
    private var startSound = DictationSound.start

    init() {
        Task { [weak self] in
            let rendered = await Task.detached(priority: .utility) {
                DictationSound.allCases.map { ($0, Self.wav($0.render(), sampleRate: SoundSynth.sampleRate)) }
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
    func playStart(mouth: Bool) -> (at: Date, cue: StartCue)? {
        // A grin's pop out still to come belongs to the last turn.
        for ending in [DictationSound.mouthGrin, .mouthGrimace] { fadeOut(ending) }
        let sound = DictationSound.start(mouth: mouth)
        guard let start = players[sound] else { return nil }
        startGeneration += 1
        startSound = sound
        start.volume = 1
        start.currentTime = 0
        return start.play() ? (Date(), sound.cue) : nil
    }

    /// Fades the start sound out over a few milliseconds (a hard stop clicks).
    func stopStart() {
        guard let start = players[startSound], start.isPlaying else { return }
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
