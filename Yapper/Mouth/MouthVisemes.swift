import Accelerate
import Foundation

/// The mouth shapes the viseme net tells apart: what the rig can show for each sound.
enum MouthShape: Int, CaseIterable, Sendable {
    case rest, mbp, fv, oo, oh, ee, ah, teeth, lth, sh
}

/// How sure the net is of each `MouthShape` at one moment, in `MouthShape` order. All zero means
/// nothing is known (no net, or not read yet).
typealias MouthShapes = SIMD16<Float>

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
        history = model.layers.map { [Float](repeating: 0, count: (($0.kernel - 1) * $0.dilation + 1) * $0.inputs) }
    }

    deinit { vDSP_destroy_fftsetupD(fftSetup) }

    var lookahead: Int { model.lookahead }

    /// A new dictation: clears the audio and what the layers remember, keeps the running mean.
    func reset() {
        buffer.removeAll()
        hops = 0
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
        let top = z.max()!
        var shapes = MouthShapes()
        var total: Float = 0
        for i in 0..<min(k, 16) { let e = exp(z[i] - top); shapes[i] = e; total += e }
        return shapes / total
    }
}

/// Acts out the viseme net's shapes: the reader's syllable jaw still decides how open the mouth is,
/// the shapes decide what the lips do. Each lip channel goes pose to pose (`MouthMoveFollower`), and
/// a seal or an f/v is held long enough to read.
struct MouthShaper: Sendable {
    /// What each shape asks of the lips.
    struct Lips: Sendable {
        var wide: Float = 0, round: Float = 0, close: Float = 0, fv: Float = 0, part: Float = 0
    }

    static func lips(_ s: MouthShape) -> Lips {
        switch s {
        case .rest:  Lips()
        case .mbp:   Lips(close: 1)
        case .fv:    Lips(wide: 0.1, fv: 1)
        case .oo:    Lips(round: 1)
        case .oh:    Lips(round: 0.6)
        case .ee:    Lips(wide: 0.9, part: 0.3)
        case .ah:    Lips(wide: 0.15)
        case .teeth: Lips(wide: 0.35, part: 0.8)
        case .lth:   Lips(wide: 0.25, part: 0.3)
        case .sh:    Lips(round: 0.65, part: 0.9)
        }
    }

    /// A seal or an f/v this sure of itself is held at least `hold` seconds.
    static let hold: Float = 0.07

    private var width = MouthMoveFollower()
    private var close = MouthMoveFollower(threshold: 0.15, shortest: 0.035, perUnit: 0.03, longest: 0.065)
    private var fv = MouthMoveFollower(threshold: 0.15, shortest: 0.035, perUnit: 0.03, longest: 0.065)
    private var part = MouthMoveFollower()
    private var closeHeld: (v: Float, left: Float) = (0, 0)
    private var fvHeld: (v: Float, left: Float) = (0, 0)

    mutating func reset() {
        width.reset(); close.reset(); fv.reset(); part.reset()
        closeHeld = (0, 0); fvHeld = (0, 0)
    }

    /// The goals for one moment: the shapes' lips weighted by how sure the net is. A seal and an f/v
    /// need the net to be fairly sure, so a maybe doesn't flicker the lips shut.
    static func goal(_ p: MouthShapes) -> Lips {
        var g = Lips()
        for s in MouthShape.allCases where s != .mbp && s != .fv {
            let l = lips(s), k = p[s.rawValue]
            g.wide += k * l.wide; g.round += k * l.round; g.part += k * l.part
        }
        g.close = MouthRig.smooth(0.2, 0.6, p[MouthShape.mbp.rawValue])
        g.fv = MouthRig.smooth(0.2, 0.6, p[MouthShape.fv.rawValue])
        g.wide += p[MouthShape.fv.rawValue] * lips(.fv).wide
        return g
    }

    /// Eases towards `shapes` by `dt`; returns the reader's width replaced by the shapes' (wide minus
    /// round, for `MouthPerformance`), and the seal, f/v and lip part to lay over its pose.
    mutating func step(_ shapes: MouthShapes, dt: Float) -> (W: Float, close: Float, fv: Float, part: Float) {
        let g = Self.goal(shapes)
        func held(_ x: Float, _ h: inout (v: Float, left: Float)) -> Float {
            h.left -= dt
            if x >= 0.5 && x >= h.v || h.left <= 0 { h = (x, x >= 0.5 ? Self.hold : 0) }
            return max(x, h.left > 0 ? h.v : 0)
        }
        let c = held(g.close, &closeHeld), f = held(g.fv, &fvHeld)
        return (width.step(g.wide - g.round, dt: dt), close.step(c, dt: dt), fv.step(f, dt: dt), part.step(g.part, dt: dt))
    }

    /// Lays the seal, f/v and part over a pose `MouthPerformance` made. The seal closes the jaw a
    /// little too, so the lips aren't stretched over a wide-open mouth.
    static func apply(close: Float, fv: Float, part: Float, to p: inout MouthPose) {
        p.close = max(p.close, close)
        p.J *= 1 - 0.35 * close
        p.fv = max(p.fv, fv)
        p.part = max(p.part, part * (1 - p.J))
    }
}
