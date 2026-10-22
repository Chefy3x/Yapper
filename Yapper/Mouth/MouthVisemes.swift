import Accelerate
import Foundation
import simd

/// The mouth shapes the viseme net tells apart: what the rig can show for each sound. The small nets
/// hear 10 (`l` is l and th together); the WavLM ear hears `th` apart, with the tongue between the teeth.
enum MouthShape: Int, CaseIterable, Sendable {
    case rest, mbp, fv, oo, oh, ee, ah, teeth, l, sh, th
}

/// How sure the net is of each `MouthShape` at one moment, in `MouthShape` order. All zero means
/// nothing is known (no net, or not read yet). Lane `MouthShape.steadyLane` is 1 while the sound is
/// steady (a held sound): the mouth keeps the shape it has.
typealias MouthShapes = SIMD16<Float>

extension MouthShape {
    static let steadyLane = 15
}

/// The viseme net's weights and feature settings, exported by `tools/mouth/visemes.py export`.
///
/// File layout: "MVIS", UInt32 version, UInt32 header length, the JSON header, then little-endian
/// float32 arrays: the running mean's start and the spread per mel band, then each conv layer's
/// weights (out, in, kernel) and bias (BatchNorm already folded in), then the output layer's
/// weights (classes, channels) and bias.
struct MouthVisemeModel: Sendable {
    struct Header: Decodable, Sendable {
        struct Layer: Decodable, Sendable { var kernel: Int; var dilation: Int; var lookahead: Int }
        var sampleRate: Double
        var win: Int, hop: Int, nfft: Int, mels: Int
        var fmin: Double, fmax: Double, logEps: Double, ema: Double
        var channels: Int
        var classes: [String]
        var layers: [Header.Layer]
    }
    struct Layer: Sendable {
        var kernel: Int, dilation: Int, lookahead: Int
        var inputs: Int, outputs: Int
        /// (out, in * kernel): for each output, the input taps oldest first, laid out per input channel.
        var weights: [Float]
        var bias: [Float]
    }
    enum LoadError: Error { case notAModel, missing }

    let header: Header
    let mean0: [Double], spread: [Double]
    let layers: [Layer]
    let outWeights: [Float], outBias: [Float]
    /// Hops between hearing a hop and knowing its shape.
    var lookahead: Int { layers.reduce(0) { $0 + $1.lookahead } }

    init(data: Data) throws {
        guard data.count > 12, data.prefix(4) == Data("MVIS".utf8) else { throw LoadError.notAModel }
        func u32(_ at: Int) -> Int { Int(data.subdata(in: at..<at + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }) }
        let n = u32(8)
        header = try JSONDecoder().decode(Header.self, from: data.subdata(in: 12..<12 + n))
        let count = (data.count - 12 - n) / 4
        var floats = [Float](repeating: 0, count: count)
        _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0, from: (12 + n)..<(12 + n + count * 4)) }
        var at = 0
        func take(_ k: Int) throws -> [Float] {
            guard at + k <= floats.count else { throw LoadError.missing }
            defer { at += k }
            return Array(floats[at..<at + k])
        }
        let M = header.mels, C = header.channels
        mean0 = try take(M).map(Double.init)
        spread = try take(M).map(Double.init)
        var layers: [Layer] = []
        var cin = M
        for l in header.layers {
            let w = try take(C * cin * l.kernel)
            // reorder (out, in, k) to (out, k, in) so one hop's taps line up as k input vectors
            var r = [Float](repeating: 0, count: w.count)
            for o in 0..<C { for i in 0..<cin { for j in 0..<l.kernel {
                r[(o * l.kernel + j) * cin + i] = w[(o * cin + i) * l.kernel + j]
            } } }
            layers.append(Layer(kernel: l.kernel, dilation: l.dilation, lookahead: l.lookahead,
                                inputs: cin, outputs: C, weights: r, bias: try take(C)))
            cin = C
        }
        self.layers = layers
        outWeights = try take(header.classes.count * C)
        outBias = try take(header.classes.count)
        guard at == floats.count else { throw LoadError.missing }
    }

    static func bundled() throws -> MouthVisemeModel {
        guard let url = Bundle.main.url(forResource: "visemes", withExtension: "bin") else { throw LoadError.missing }
        return try MouthVisemeModel(data: Data(contentsOf: url))
    }

}

/// Reads mouth shapes from the voice: 16 kHz mono in, one `MouthShapes` per 10 ms hop out, `lookahead`
/// hops (40 ms) after that hop was heard. A port of `Features` and `Stream` in tools/mouth/visemes.py;
/// MouthVisemesTests checks the two agree.
///
/// Per hop: a 25 ms Hamming window, a 512-point power spectrum, 40 log-mel bands, the running mean
/// of each band (about 3 s) taken off so the mic's gain and colour drop out. Then a stack of 1-D
/// convolutions, each keeping the last few hops it was fed, and a softmax.
///
/// Hops line up with `MouthReader`'s when both are fed the same samples from a reset. Not
/// thread-safe: create it and feed it from one serial queue.
final class MouthVisemes {
    let model: MouthVisemeModel
    private let hamming: [Double]
    private let bank: [Double]          // (mels, nfft/2 + 1)
    private let fftSetup: FFTSetupD
    private let log2n: Int
    private var buffer: [Double] = []
    /// The running mean per band. Kept across `reset`, so the mouth starts tuned to this mic.
    private(set) var mean: [Double]
    private var history: [[Float]]      // per layer: its last (k-1)*d+1 inputs, oldest first, flattened
    private var hops = 0
    private var hum: MouthHum
    private var steadiness = MouthSteady()
    private var steadies: [Bool] = []
    /// Whether a held hum was sounding, for the last `lookahead` + 1 hops, oldest first.
    private var hums: [Bool] = []

    init(model: MouthVisemeModel) {
        self.model = model
        let h = model.header
        hamming = (0..<h.win).map { 0.54 - 0.46 * cos(2 * Double.pi * Double($0) / Double(h.win - 1)) }
        bank = Self.melBank(h)
        var l = 0
        while 1 << l < h.nfft { l += 1 }
        log2n = l
        fftSetup = vDSP_create_fftsetupD(vDSP_Length(l), FFTRadix(kFFTRadix2))!
        mean = model.mean0
        hum = MouthHum(model.header)
        history = model.layers.map { [Float](repeating: 0, count: (($0.kernel - 1) * $0.dilation + 1) * $0.inputs) }
    }

    deinit { vDSP_destroy_fftsetupD(fftSetup) }

    var lookahead: Int { model.lookahead }

    /// A new dictation: clears the audio and what the layers remember, keeps the running mean.
    func reset() {
        buffer.removeAll()
        hops = 0
        hum.reset(); hums.removeAll(); steadiness.reset(); steadies.removeAll()
        for i in history.indices { history[i] = [Float](repeating: 0, count: history[i].count) }
    }

    /// Feeds samples; returns one entry per completed hop: the shapes for the hop `lookahead` hops
    /// back, or nil while the first `lookahead` hops fill.
    func feed(_ samples: UnsafeBufferPointer<Float>) -> [MouthShapes?] {
        let win = model.header.win, hop = model.header.hop
        buffer.reserveCapacity(buffer.count + samples.count)
        for s in samples { buffer.append(Double(s)) }
        var out: [MouthShapes?] = []
        var start = 0
        while buffer.count - start >= win {
            out.append(step(logMel(Array(buffer[start..<start + win]))))
            start += hop
        }
        buffer.removeFirst(start)
        return out
    }

    func feed(_ samples: [Float]) -> [MouthShapes?] { samples.withUnsafeBufferPointer { feed($0) } }

    // MARK: - Features

    /// HTK mel triangles from `fmin` to `fmax` over the power spectrum's bins (`mel_bank`).
    static func melBank(_ h: MouthVisemeModel.Header) -> [Double] {
        func mel(_ f: Double) -> Double { 2595 * log10(1 + f / 700) }
        func hz(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }
        let lo = mel(h.fmin), hi = mel(h.fmax), bins = h.nfft / 2 + 1
        let pts = (0..<h.mels + 2).map { hz(lo + (hi - lo) * Double($0) / Double(h.mels + 1)) }
        var bank = [Double](repeating: 0, count: h.mels * bins)
        for i in 0..<h.mels {
            let a = pts[i], b = pts[i + 1], c = pts[i + 2]
            for k in 0..<bins {
                let f = Double(k) * h.sampleRate / Double(h.nfft)
                bank[i * bins + k] = max(0, min((f - a) / (b - a), (c - f) / (c - b)))
            }
        }
        return bank
    }

    /// One window's log-mel bands (`log_mel`).
    func logMel(_ seg: [Double]) -> [Double] {
        let h = model.header, half = h.nfft / 2
        var input = [Double](repeating: 0, count: h.nfft)
        vDSP_vmulD(seg, 1, hamming, 1, &input, 1, vDSP_Length(h.win))
        var re = [Double](repeating: 0, count: half), im = [Double](repeating: 0, count: half)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                input.withUnsafeBytes { raw in
                    vDSP_ctozD(raw.bindMemory(to: DSPDoubleComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zripD(fftSetup, &split, 1, vDSP_Length(log2n), FFTDirection(kFFTDirection_Forward))
            }
        }
        // vDSP's real FFT is scaled by 2 and packs the Nyquist bin into im[0]
        var power = [Double](repeating: 0, count: half + 1)
        power[0] = re[0] * re[0] / 4
        power[half] = im[0] * im[0] / 4
        for k in 1..<half { power[k] = (re[k] * re[k] + im[k] * im[k]) / 4 }
        var mels = [Double](repeating: 0, count: h.mels)
        vDSP_mmulD(bank, 1, power, 1, &mels, 1, vDSP_Length(h.mels), 1, vDSP_Length(half + 1))
        return mels.map { log($0 + h.logEps) }
    }

    // MARK: - The net, one hop at a time

    private func step(_ lm: [Double]) -> MouthShapes? {
        let ema = model.header.ema
        var x = [Float](repeating: 0, count: lm.count)
        for i in lm.indices {
            mean[i] += ema * (lm[i] - mean[i])
            x[i] = Float((lm[i] - mean[i]) / model.spread[i])
        }
        hums.append(hum.step(lm, mean: mean))
        if hums.count > lookahead + 1 { hums.removeFirst(hums.count - lookahead - 1) }
        steadies.append(steadiness.step(lm))
        if steadies.count > lookahead + 1 { steadies.removeFirst(steadies.count - lookahead - 1) }
        defer { hops += 1 }
        var lag = 0
        for (li, layer) in model.layers.enumerated() {
            let cin = layer.inputs, span = (layer.kernel - 1) * layer.dilation + 1
            // shift the history one hop and put this input last
            history[li].withUnsafeMutableBufferPointer { h in
                let base = h.baseAddress!
                base.update(from: base + cin, count: (span - 1) * cin)
                (base + (span - 1) * cin).update(from: x, count: cin)
            }
            lag += layer.lookahead
            if hops < lag { return nil }
            // gather the k taps, oldest first, and run them through the layer as one matrix product
            var taps = [Float](repeating: 0, count: layer.kernel * cin)
            history[li].withUnsafeBufferPointer { h in
                taps.withUnsafeMutableBufferPointer { t in
                    for j in 0..<layer.kernel {
                        (t.baseAddress! + j * cin).update(from: h.baseAddress! + j * layer.dilation * cin, count: cin)
                    }
                }
            }
            var y = [Float](repeating: 0, count: layer.outputs)
            vDSP_mmul(layer.weights, 1, taps, 1, &y, 1, vDSP_Length(layer.outputs), 1, vDSP_Length(layer.kernel * cin))
            vDSP_vadd(y, 1, layer.bias, 1, &y, 1, vDSP_Length(layer.outputs))
            var zero: Float = 0
            vDSP_vthr(y, 1, &zero, &y, 1, vDSP_Length(layer.outputs))     // ReLU
            if li > 0 {
                // residual: this layer's input at the hop it answers for
                let at = (span - 1 - layer.lookahead) * cin
                history[li].withUnsafeBufferPointer { h in
                    vDSP_vadd(y, 1, h.baseAddress! + at, 1, &y, 1, vDSP_Length(cin))
                }
            }
            x = y
        }
        let k = model.outBias.count
        var z = [Float](repeating: 0, count: k)
        vDSP_mmul(model.outWeights, 1, x, 1, &z, 1, vDSP_Length(k), 1, vDSP_Length(x.count))
        vDSP_vadd(z, 1, model.outBias, 1, &z, 1, vDSP_Length(k))
        var shapes = MouthShapes()
        if hums[0] {                                    // a held hum at the hop answered for: m
            shapes[MouthShape.mbp.rawValue] = 1
        } else {
            let top = z.max()!
            var total: Float = 0
            for i in 0..<min(k, MouthShape.steadyLane) { let e = exp(z[i] - top); shapes[i] = e; total += e }
            shapes /= total
        }
        shapes[MouthShape.steadyLane] = steadies[0] ? 1 : 0
        return shapes
    }
}

/// Whether the sound is steady (`Steady` in tools/mouth/visemes.py): a held sound barely changes from
/// hop to hop, while speech changes all the time. The change is the mean log-mel difference over
/// 50 ms across the bands under ~4 kHz, averaged over 100 ms. It depends on how much the sound
/// changes, not how it sounds, so it holds on any mic.
struct MouthSteady: Sendable {
    static let bands = 30, lag = 5, average = 10
    static let below = 0.75
    private var rows: [[Double]] = []
    private var changes: [Double] = []

    mutating func reset() { rows = []; changes = [] }

    mutating func step(_ lm: [Double]) -> Bool {
        rows.append(Array(lm.prefix(Self.bands)))
        if rows.count > Self.lag + 1 { rows.removeFirst() }
        var d = 0.0
        if rows.count > Self.lag {
            d = zip(rows[rows.count - 1], rows[0]).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(Self.bands)
        }
        changes.append(d)
        if changes.count > Self.average { changes.removeFirst() }
        return changes.reduce(0, +) / Double(changes.count) < Self.below
    }
}

/// A held hum ("mmm"), caught from the sound itself (`Hum` in tools/mouth/visemes.py). The net hears a
/// held m poorly: in speech an m lasts ~60 ms, and held hums are rare in what it learned from. A hum
/// has a clear fingerprint: the low hum under 400 Hz, a nasal band at 1–2 kHz well below it, and
/// almost nothing above 2 kHz. It has to last 120 ms before it counts, so an m inside a word is left
/// to the net; on other speakers it fires on 0.04% of their speech.
struct MouthHum: Sendable {
    /// Bands in dB against 80–400 Hz must fall in these: 400 Hz–1 kHz, 1–2 kHz, then below for
    /// 2–4 kHz and 4–8 kHz.
    static let bands: [(Double, Double)] = [(80, 400), (400, 1000), (1000, 2000), (2000, 4000), (4000, 8000)]
    static let loMid = (-17.0, -5.0), mid = (-15.0, -3.0), hi = -14.0, top = -24.0
    /// 120 ms in the box before it counts, no quieter than this against the running mean level.
    static let hold = 12, loudDb = -8.0

    let index: [[Int]]
    private var run = 0

    init(_ h: MouthVisemeModel.Header) {
        func mel(_ f: Double) -> Double { 2595 * log10(1 + f / 700) }
        func hz(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }
        let lo = mel(h.fmin), hi = mel(h.fmax)
        let centres = (1...h.mels).map { hz(lo + (hi - lo) * Double($0) / Double(h.mels + 1)) }
        index = Self.bands.map { b in centres.indices.filter { centres[$0] >= b.0 && centres[$0] < b.1 } }
    }

    mutating func reset() { run = 0 }

    /// One hop's log-mel and the running mean (after this hop): whether a held hum is sounding.
    mutating func step(_ lm: [Double], mean: [Double]) -> Bool {
        let e = index.map { ix in ix.reduce(1e-9) { $0 + exp(lm[$1]) } }
        let rel = e.dropFirst().map { 10 * log10($0 / e[0]) }
        let level = 10 * log10(e.reduce(0, +)), ref = 10 * log10(mean.reduce(1e-9) { $0 + exp($1) })
        let box = rel[0] > Self.loMid.0 && rel[0] < Self.loMid.1 && rel[1] > Self.mid.0 && rel[1] < Self.mid.1
            && rel[2] < Self.hi && rel[3] < Self.top && level > ref + Self.loudDb
        run = box ? run + 1 : 0
        return run >= Self.hold
    }
}

/// The jaw's weight. The shapes put it wide open for an "ah" and shut for a t or a b, which is right
/// for a held sound but flaps on fast speech, so it eases there at about `openHz` and `closeHz`: a quick syllable gets
/// part of the way, a held one all of it.
struct MouthJawMass: Sendable {
    static let openHz: Float = 6.5, closeHz: Float = 4
    private var x: Float?, v: Float = 0

    mutating func reset() { x = nil; v = 0 }

    /// A critically damped spring, in 5 ms substeps.
    mutating func step(_ target: Float, dt: Float) -> Float {
        guard var p = x, dt > 0 else { x = target; v = 0; return target }
        let w = 2 * Float.pi * (target > p ? Self.openHz : Self.closeHz), n = max(1, Int((dt / 0.005).rounded(.up))), h = dt / Float(n)
        for _ in 0..<n { v += (w * w * (target - p) - 2 * w * v) * h; p += v * h }
        x = p
        return p
    }
}

/// Acts out the viseme net's shapes, posed from reference video of a real mouth making each sound.
/// The reader's syllable jaw decides how open the mouth is, up to the most each shape allows: m/b/p,
/// f/v, s/t and sh are all made with the teeth nearly together however loud they are. The lips do
/// what the shape asks, each channel pose to pose (`MouthMoveFollower`), and a seal or an f/v is held
/// long enough to read.
struct MouthShaper: Sendable {
    /// What each shape asks of the mouth.
    struct Lips: Sendable, Equatable {
        /// Spread (+) or round (-), for `MouthPerformance`'s width.
        var wide: Float = 0, round: Float = 0
        /// Lips sealed (m/b/p), lower lip tucked under the top teeth (f/v), lips parted over the teeth.
        var close: Float = 0, fv: Float = 0, part: Float = 0
        /// The most the jaw may open for this shape (0 shut … 1 a big "ah"), and the least: an O
        /// opens wide enough to show the dark between the teeth however quietly it's said.
        var jaw: Float = 1.2, open: Float = 0
        /// The top lip lifted off the top teeth (+) or drawn down over them (-), and the bottom lip
        /// dropped off the bottom teeth (+) or riding up over them (-), as `upperUp` / `lowerDown`.
        var upper: Float = 0, lower: Float = 0
        /// Lips pressed together and in (m/b/p).
        var press: Float = 0
        /// Lips pushed out in a trumpet with the teeth close behind (sh).
        var flare: Float = 0
        /// Corners pulled up and back (ee, s).
        var smile: Float = 0
        /// The tongue lifted towards the top teeth (ee, l) and brought forward over the bottom ones (ah).
        var tongue: Float = 0, tongueOut: Float = 0
        /// The tongue's tip out between the teeth (th).
        var tongueTip: Float = 0
    }

    static func lips(_ s: MouthShape) -> Lips {
        switch s {
        case .rest:  Lips()
        case .mbp:   Lips(close: 1, jaw: 0.04, press: 0.45)
        case .fv:    Lips(wide: 0.15, fv: 1, jaw: 0, upper: 0.9)
        case .oo:    Lips(round: 1, jaw: 0.75, open: 0.65, tongueOut: 0.1)
        case .oh:    Lips(round: 0.55, jaw: 1.7, open: 1.4, lower: -1.5, tongueOut: 0.3)
        case .ee:    Lips(wide: 1, part: 1, jaw: 0.75, open: 0.6, upper: 2.6, lower: -5.5, smile: 2.6, tongue: 0.7, tongueOut: 0.3)
        case .ah:    Lips(round: 0.2, jaw: 1.7, open: 1.35, upper: -1.3, lower: -4.5, tongue: 0.8, tongueOut: 1)
        case .teeth: Lips(wide: 0.8, part: 1, jaw: 0.14, upper: 0.9, lower: 1.8, smile: 1.4)
        case .l:     Lips(jaw: 1.0, open: 0.7, upper: -0.5, lower: -3, tongue: 1)
        case .th:    Lips(wide: 0.3, part: 1, jaw: 0.3, open: 0.25, upper: 1.0, lower: 3.0, smile: 0.3, tongue: 0.8, tongueTip: 1)
        case .sh:    Lips(round: 0.3, part: 1, jaw: 0.2, upper: 0.9, lower: 1.8, flare: 1)
        }
    }

    /// A seal or an f/v is held at least `hold` seconds.
    static let hold: Float = 0.07
    /// The way an animator times a mouth: the net's answers are eased over `listen` seconds, the
    /// mouth commits to one shape and keeps it at least `minHold`, and only changes for a shape
    /// that's clearly ahead (`margin`). A seal, an f/v or an open vowel the net is sure of cuts in
    /// sooner: they're what reads, and a short vowel ("but", "something") is over in 50 ms.
    /// While the sound is steady (a held sound) it doesn't change at all.
    static let listen: Float = 0.03, minHold: Float = 0.15, margin: Float = 0.25
    /// How sure the net must be of a shape before its minimum opening applies in full.
    static let sureOpen: Float = 0.8

    private var width = MouthMoveFollower()
    private var close = MouthMoveFollower(threshold: 0.15, shortest: 0.035, perUnit: 0.03, longest: 0.065)
    private var fv = MouthMoveFollower(threshold: 0.15, shortest: 0.035, perUnit: 0.03, longest: 0.065)
    private var jaw = MouthMoveFollower(threshold: 0.08, shortest: 0.035, perUnit: 0.04, longest: 0.08)
    private var open = MouthMoveFollower()
    private var part = MouthMoveFollower()
    private var upper = MouthMoveFollower(), lower = MouthMoveFollower()
    private var press = MouthMoveFollower(threshold: 0.12, shortest: 0.035, perUnit: 0.03, longest: 0.065)
    private var flare = MouthMoveFollower()
    private var smile = MouthMoveFollower()
    private var tongue = MouthMoveFollower(), tongueOut = MouthMoveFollower(), tongueTip = MouthMoveFollower()
    private var heard: MouthShapes?
    private var shown: MouthShape?
    /// A seal or an f/v the mouth has moved on from before the lips got there, and the lips last time.
    private var landing: (close: Bool, fv: Bool) = (false, false)
    private var last = Lips()
    private var shownFor: Float = 0

    /// The shape the mouth is committed to, if any yet.
    var committed: MouthShape? { shown }

    mutating func reset() {
        width.reset(); close.reset(); fv.reset(); jaw.reset(); open.reset(); part.reset(); upper.reset(); lower.reset(); press.reset(); flare.reset(); smile.reset(); tongue.reset(); tongueOut.reset(); tongueTip.reset()
        heard = nil; shown = nil; shownFor = 0; landing = (false, false); last = Lips()
    }

    /// Eases the net's answer and decides which shape the mouth shows: the one it's showing until
    /// it has been held `minHold` and another is ahead by `margin`.
    mutating func commit(_ shapes: MouthShapes, dt: Float) -> MouthShape {
        var h = heard ?? shapes
        h += (shapes - h) * (1 - exp(-dt / Self.listen))
        heard = h
        let top = MouthShape.allCases.max { h[$0.rawValue] < h[$1.rawValue] }!
        shownFor += dt
        let steady = shapes[MouthShape.steadyLane] > 0.5    // a held sound: keep the shape
        if let now = shown, top != now, !steady {
            let cutIn = (top == .mbp || top == .fv || top == .ah || top == .oh) && h[top.rawValue] > 0.5
            // a seal or an f/v is over in a moment: holding it the full `minHold` would keep the
            // mouth shut through the vowel after it ("my", "but")
            let least = now == .mbp || now == .fv ? Self.hold : Self.minHold
            if cutIn && h[top.rawValue] > h[now.rawValue] || shownFor >= least && h[top.rawValue] > h[now.rawValue] + Self.margin { shown = top; shownFor = 0 }
        } else if shown == nil { shown = top; shownFor = 0 }
        return shown!
    }

    /// The goals for one moment: the shapes weighted by how sure the net is. A seal and an f/v need
    /// the net to be fairly sure, so a maybe doesn't flicker the lips shut; the jaw's limit follows
    /// the seal and the f/v the same way.
    static func goal(_ p: MouthShapes) -> Lips {
        var g = Lips(jaw: 0)
        for s in MouthShape.allCases {
            let l = lips(s), k = p[s.rawValue]
            g.wide += k * l.wide; g.round += k * l.round; g.part += k * l.part
            g.open += k * l.open; g.upper += k * l.upper; g.lower += k * l.lower; g.flare += k * l.flare; g.smile += k * l.smile; g.tongue += k * l.tongue; g.tongueOut += k * l.tongueOut; g.tongueTip += k * l.tongueTip
            if s != .mbp && s != .fv { g.jaw += k * l.jaw }
        }
        let m = MouthRig.smooth(0.2, 0.6, p[MouthShape.mbp.rawValue])
        let f = MouthRig.smooth(0.2, 0.6, p[MouthShape.fv.rawValue])
        g.close = m; g.fv = f; g.press = m * lips(.mbp).press
        // what's left of the jaw's limit, once the seal and the f/v have had their say
        let rest = max(1e-3, 1 - p[MouthShape.mbp.rawValue] - p[MouthShape.fv.rawValue])
        g.jaw /= rest
        g.jaw += (lips(.mbp).jaw - g.jaw) * m
        g.jaw += (lips(.fv).jaw - g.jaw) * f * (1 - m)
        return g
    }

    /// Eases towards `shapes` by `dt`.
    mutating func step(_ shapes: MouthShapes, dt: Float) -> Lips {
        let shown = commit(shapes, dt: dt)
        var one = MouthShapes(); one[shown.rawValue] = 1
        var g = Self.goal(one)
        // a shape that opens the jaw (oo, ah, l) opens it only as far as the net is sure of it, so a
        // moment's mishearing doesn't throw the jaw open
        if let h = heard { g.open *= min(1, h[shown.rawValue] / Self.sureOpen) }
        // a seal or an f/v still lands after a shorter one the net moved on from, but no longer:
        // holding it past that kept the jaw shut through the vowel after it ("but")
        if shown == .mbp { landing.close = true } else if last.close >= 0.8 { landing.close = false }
        if shown == .fv { landing.fv = true } else if last.fv >= 0.8 { landing.fv = false }
        let c = landing.close ? 1 : g.close, f = landing.fv ? 1 : g.fv
        // a seal or f/v keeps the jaw shut with it
        let cap = min(g.jaw, Self.lips(.mbp).jaw + (MouthRig.jawLimit - Self.lips(.mbp).jaw) * (1 - c),
                      Self.lips(.fv).jaw + (MouthRig.jawLimit - Self.lips(.fv).jaw) * (1 - f))
        let w = width.step(g.wide - g.round, dt: dt)
        last = Lips(wide: max(0, w), round: max(0, -w), close: close.step(c, dt: dt), fv: fv.step(f, dt: dt),
                    part: part.step(g.part, dt: dt), jaw: jaw.step(cap, dt: dt), open: open.step(g.open, dt: dt), upper: upper.step(g.upper, dt: dt), lower: lower.step(g.lower, dt: dt),
                    press: press.step(Self.lips(.mbp).press * c, dt: dt), flare: flare.step(g.flare, dt: dt),
                    smile: smile.step(g.smile, dt: dt), tongue: tongue.step(g.tongue, dt: dt), tongueOut: tongueOut.step(g.tongueOut, dt: dt), tongueTip: tongueTip.step(g.tongueTip, dt: dt))
        return last
    }

    /// The width to hand `MouthPerformance` in place of the reader's.
    static func width(_ l: Lips) -> Float { l.wide - l.round }

    /// Lays the shape over a pose `MouthPerformance` made: the jaw held under the shape's limit, the
    /// round re-made for that jaw (an O opened at least `open`), then the seal, the f/v, the press, the flare and the lips on or off the teeth.
    /// `weigh` takes the jaw the shape wants and gives the one shown (the director's `MouthJawMass`);
    /// the seal and the f/v shut it after that, at their own speed.
    static func apply(_ l: Lips, to p: inout MouthPose, weigh: (Float) -> Float = { $0 }) {
        p.J = weigh(max(min(p.J, max(0, l.jaw)), l.open))
        // lips can only seal over a nearly shut jaw: the jaw shuts in step with the seal, not after it
        p.J = min(p.J, Self.lips(.mbp).jaw + max(0, 1 - 1.5 * l.close) * MouthRig.jawLimit)
        // ... and the bottom lip can only reach the top teeth over one: the same for an f/v
        p.J = min(p.J, Self.lips(.fv).jaw + max(0, 1 - 1.5 * l.fv) * MouthRig.jawLimit)
        p.pucker = l.round
        p.funnel = l.flare
        p.close = max(p.close, l.close)
        p.fv = max(p.fv, l.fv)
        p.part = max(p.part, l.part * (1 - p.J))
        p.rollUpper = max(p.rollUpper, l.press); p.rollLower = max(p.rollLower, l.press, 0.35 * l.fv)
        // lifting a lip takes the most of it and the acting; covering the teeth pulls it back by that much
        p.upperUp = simd_max(p.upperUp, SIMD2(repeating: l.upper)) + SIMD2(repeating: min(0, l.upper))
        // the bottom lip only rides up over the bottom teeth as far as the jaw has dropped them
        p.lowerDown = simd_max(p.lowerDown, SIMD2(repeating: l.lower)) + SIMD2(repeating: min(0, l.lower) * MouthRig.smooth(0.3, 0.65, p.J))
        p.smile = simd_max(p.smile, SIMD2(repeating: l.smile))
        p.tongue = max(p.tongue, l.tongue); p.tongueOut = max(p.tongueOut, l.tongueOut); p.tongueTip = max(p.tongueTip, l.tongueTip)
    }
}
