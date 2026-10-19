import Accelerate
import Foundation

/// One Loud Mouth pose, produced for every 10 ms of microphone audio.
struct MouthFrame: Equatable, Sendable {
    /// Seconds since the reader started, at the end of the audio this frame has heard.
    var t: Double
    /// Jaw open: 0 shut, about 1 wide; the spring can overshoot to 1.2.
    var J: Float
    /// Lip width: positive spreads the lips (ee), negative rounds and puckers them (oo), -1...1.
    var W: Float
    /// Teeth together (s, sh, consonant closures), 0...1.
    var T: Float
    /// The speech gate, including its 60 ms hangover. After it drops the jaw fades shut over 300 ms.
    var speaking: Bool
}

/// The reader's running picture of the speaker and the room: formant and loudness averages and the
/// noise floor. Starts from typical adult values; keep it between sessions so the mouth starts tuned
/// to this voice and mic.
struct SpeakerStats: Codable, Equatable, Sendable {
    var f1Mean = 520.0      // Hz, LPC F1 on voiced speech
    var f1Std = 160.0
    var f2Mean = 1550.0     // Hz, LPC F2
    var f2Std = 400.0
    var loudMean = 24.0     // dB above the noise floor, on speech
    var loudStd = 9.0
    var floorDb = -40.0     // the noise floor the speech gate starts from
    var weight = 50.0       // how many frames of evidence the values above carry

    static let typical = SpeakerStats()
}

/// The live voice reader behind the Loud Mouth: 16 kHz mono samples in, one `MouthFrame` per 10 ms hop
/// out, using only audio it has already heard.
///
/// A port of `tools/mouth/reader_live.py`, which was tuned against real lip movement and is where
/// changes start: edit the Python, regenerate `YapperTests/Fixtures/mouth_reader_synth.json`, then
/// mirror the change here until `MouthReaderTests` passes.
///
/// Per hop: a 25 ms Hamming window gives the level, the 150–1000 Hz level, the share of energy above
/// 4 kHz (hiss), voicing from the autocorrelation, and F1/F2 from peaks of the LPC envelope. A speech
/// gate against the 2 s minimum level drives a continuous jaw envelope with an onset pop; soft vowel
/// classes set the width; hiss brings the teeth together. Near-critical springs smooth all three.
///
/// Not thread-safe: create it and feed it from one serial queue.
final class MouthReader {
    // Tuning, mirrored from reader_live.py. Times are in 10 ms hops unless named otherwise.
    private enum K {
        static let gateDb = 10.0            // speech when the level is this far above the 2 s minimum
        static let hang = 6                 // speech gate hangover, 60 ms
        static let fade = 30                // phrase-end fade, 300 ms
        static let floorBlock = 25, floorBlocks = 8   // 8 blocks of 250 ms = the 2 s minimum window
        static let voicedForFormants = 0.45
        static let jawFloor = 0.2           // the jaw never shuts fully inside speech
        static let jawBase = 0.25, jawSlope = 0.33    // envelope at the speaker's average level, per std
        static let popDb = 14.0, popSize = 0.12, popTau = 5.0   // onset pop: low-band rise in 40 ms
        static let loudTau = 2.0            // the level is eased over 20 ms before it drives the jaw
        static let shapeTau = 2.0           // vowel width eases to a new vowel over ~20 ms
        static let jawMulTau = 6.0          // the vowel's jaw multiplier eases slower, ~60 ms
        static let formantMedian = 3        // vowel read from the median of this many formant readings
        static let voicedLo = 0.30, voicedHi = 0.60   // voicing over which vowel width takes over
        static let statsMax = 1500.0        // formant stats never weigh more than this many frames
        static let loudMax = 300.0          // loudness forgets faster (~3 s of speech)
        static let soft = 0.25              // softness of the vowel-class boundaries, in z units
        static let widthGain = 1.25         // restores the range the soft classes blend away
        static let hissClose = 0.3          // s / sh / f close the jaw this much of the way
        // v3's lip width per vowel class
        static let widthAh = 0.0, widthOo = -0.95, widthOh = -0.55, widthEe = 0.9, widthUh = 0.3
    }

    let sampleRate: Double
    private(set) var stats: SpeakerStats

    private let hop: Int, win: Int, nfft: Int, log2n: Int, order: Int
    private let hamming: [Double]
    private let lowBand: Range<Int>, hissBin: Int
    private let lagLo: Int, lagHi: Int
    private let formantLo: Int, formantHi: Int
    private let fftSetup: FFTSetupD

    private var buffer: [Double] = []
    private var hops = 0
    // speech gate
    private var blocks: [Double]
    private var blockMin = Double.infinity, blockCount = 0
    private var hang = 0, fadeCount = K.fade
    // state held across hops
    private var lows = [Double](repeating: -120, count: 4)
    private var formantHistory: [(f1: Double, f2: Double)] = []
    private var pop = 0.0, loudEased = 0.0
    private var vowelWidth = 0.0, vowelJawMul = 1.0
    private var widthEased = 0.0, jawMulEased = 1.0
    private var last = (J: 0.0, W: 0.0, T: 0.0)
    private var jaw = Spring(up: 9, down: 10.5, zeta: 0.85)
    private var width = Spring(up: 7, down: 7, zeta: 0.9)
    private var teeth = Spring(up: 10, down: 10, zeta: 0.9)

    init(sampleRate: Double = 16_000, stats: SpeakerStats? = nil) {
        self.sampleRate = sampleRate
        self.stats = stats ?? .typical
        hop = Int((0.010 * sampleRate).rounded())
        let win = Int((0.025 * sampleRate).rounded())
        self.win = win
        var n = 1, l = 0
        while n < win { n <<= 1; l += 1 }
        nfft = n; log2n = l
        order = 2 + Int(sampleRate) / 1000
        hamming = (0..<win).map { 0.54 - 0.46 * cos(2 * Double.pi * Double($0) / Double(win - 1)) }
        let df = sampleRate / Double(n)
        lowBand = Int((150 / df).rounded(.up))..<Int((1000 / df).rounded(.up))
        hissBin = Int((4000 / df).rounded(.up))
        lagLo = Int(sampleRate / 400); lagHi = Int(sampleRate / 75)
        formantLo = Int(200 / df); formantHi = Int((3600 / df).rounded(.up))
        fftSetup = vDSP_create_fftsetupD(vDSP_Length(l), FFTRadix(kFFTRadix2))!
        blocks = [Double](repeating: (stats ?? .typical).floorDb, count: K.floorBlocks)
    }

    deinit { vDSP_destroy_fftsetupD(fftSetup) }

    /// Feeds any number of samples (16 kHz mono, -1...1) and returns one frame per completed 10 ms hop.
    func feed(_ samples: UnsafeBufferPointer<Float>) -> [MouthFrame] {
        buffer.reserveCapacity(buffer.count + samples.count)
        for s in samples { buffer.append(Double(s)) }
        var out: [MouthFrame] = []
        var start = 0
        while buffer.count - start >= win {
            out.append(step(Array(buffer[start..<start + win])))
            start += hop
        }
        buffer.removeFirst(start)
        return out
    }

    func feed(_ samples: [Float]) -> [MouthFrame] {
        samples.withUnsafeBufferPointer { feed($0) }
    }

    // MARK: - One hop

    private func step(_ seg: [Double]) -> MouthFrame {
        let dt = Double(hop) / sampleRate
        let (db, lowDb, hiss) = spectrum(seg)
        let voiced = voicing(seg)

        // noise floor: the minimum over the last 2 s; digital silence doesn't count
        if db > -90 { blockMin = min(blockMin, db) }
        blockCount += 1
        var floor = min(blocks.min()!, blockMin)
        if blockCount == K.floorBlock {
            blocks.removeFirst()
            blocks.append(blockMin < .infinity ? blockMin : blocks.last!)
            blockMin = .infinity; blockCount = 0
        }
        floor = max(floor, -85)
        let above = db > floor + K.gateDb
        if above { hang = K.hang } else if hang > 0 { hang -= 1 }
        let speaking = above || hang > 0

        let loud = db - floor
        loudEased += (loud - loudEased) * (1 - exp(-1 / K.loudTau))
        let rise = lowDb - lows.min()!
        lows.removeFirst(); lows.append(lowDb)

        // running stats, only from real speech
        let w = 1 / min(stats.weight + 1, K.statsMax)
        if above {
            (stats.loudMean, stats.loudStd) = Self.update(stats.loudMean, stats.loudStd, loud,
                                                          1 / min(stats.weight + 1, K.loudMax))
            stats.weight = min(stats.weight + 1, K.statsMax)
        }
        let fm = speaking && voiced > K.voicedForFormants ? formants(seg) : nil
        if let fm {
            (stats.f1Mean, stats.f1Std) = Self.update(stats.f1Mean, stats.f1Std, fm.f1, w)
            (stats.f2Mean, stats.f2Std) = Self.update(stats.f2Mean, stats.f2Std, fm.f2, w)
            formantHistory.append(fm)
            if formantHistory.count > K.formantMedian { formantHistory.removeFirst() }
        }
        if speaking { stats.floorDb = floor }

        let jt: Double, wt: Double, tt: Double
        if speaking {
            fadeCount = 0
            // jaw: a continuous envelope of the level against this speaker's running average
            let u = (loudEased - stats.loudMean) / max(stats.loudStd, 1)
            let env = K.jawFloor + (1 - K.jawFloor) * min(1, max(0, K.jawBase + K.jawSlope * u))
            // onset pop: a fast rise in the low band kicks the jaw open, then it cushions back
            if rise > K.popDb && voiced > 0.3 {
                pop = max(pop, K.popSize * min(1, (rise - K.popDb) / 8 + 0.5))
            }
            // vowel shape from the median of the last few formant readings
            if fm != nil && formantHistory.count >= 2 {
                let f1 = Self.median(formantHistory.map { $0.f1 }), f2 = Self.median(formantHistory.map { $0.f2 })
                let z1 = (f1 - stats.f1Mean) / max(stats.f1Std, 30), z2 = (f2 - stats.f2Mean) / max(stats.f2Std, 60)
                (vowelWidth, vowelJawMul) = Self.vowel(z1, z2)
            }
            widthEased += (K.widthGain * vowelWidth - widthEased) * (1 - exp(-1 / K.shapeTau))
            jawMulEased += (vowelJawMul - jawMulEased) * (1 - exp(-1 / K.jawMulTau))
            let hissy = Self.smooth(0.10, 0.25, hiss)
            let vw = Self.smooth(K.voicedLo, K.voicedHi, voiced) * (1 - hissy)
            jt = min(1.2, (env + pop) * jawMulEased) * (1 - K.hissClose * hissy)
            wt = vw * widthEased + (1 - vw) * 0.15 * hissy
            let closure = 1 - Self.smooth(0.20, 0.40, env)
            tt = max(0.85 * hissy, 0.6 * closure) * (1 - vw * (1 - closure))
            last = (jt, wt, tt)
        } else {
            // phrase end: fade the jaw shut over 300 ms; width and teeth relax with it
            fadeCount = min(K.fade, fadeCount + 1)
            let k = 1 - Double(fadeCount) / Double(K.fade)
            jt = last.J * k; wt = last.W * k; tt = 0
            if fadeCount == K.fade { formantHistory.removeAll() }
        }
        pop *= exp(-1 / K.popTau)

        let J = min(1.2, max(0, jaw.step(jt, dt)))
        let W = min(1, max(-1, width.step(wt, dt)))
        let T = min(1, max(0, teeth.step(tt, dt)))
        hops += 1
        return MouthFrame(t: Double((hops - 1) * hop + win) / sampleRate,
                          J: Float(J), W: Float(W), T: Float(T), speaking: speaking)
    }

    /// v3's vowel decision list made soft. Returns the lip width and a jaw multiplier
    /// (ah opens a little wider, ee keeps the teeth closer).
    private static func vowel(_ z1: Double, _ z2: Double) -> (width: Double, jawMul: Double) {
        let s = K.soft
        let pAh = sigmoid((z1 - 0.55) / s)                              // ah: jaw wide
        var rest = 1 - pAh
        var c = sigmoid((-0.75 - z2) / s) * sigmoid((0 - z1) / s)       // oo / ow / w: pucker
        let pOo = rest * c; rest *= 1 - c
        c = sigmoid((-0.25 - z2) / s)                                   // oh / aw / er: round
        let pOh = rest * c; rest *= 1 - c
        c = sigmoid((z2 - 0.6) / s) * sigmoid((0.1 - z1) / s)           // ee / ih: wide lips
        let pEe = rest * c, pUh = rest * (1 - c)                        // eh / ae / uh: relaxed
        let width = pAh * K.widthAh + pOo * K.widthOo + pOh * K.widthOh + pEe * K.widthEe + pUh * K.widthUh
        return (width, 1 + 0.12 * pAh - 0.3 * pEe)
    }

    // MARK: - Analysis

    /// Level in dB, 150–1000 Hz level in dB, and the share of energy above 4 kHz.
    private func spectrum(_ seg: [Double]) -> (db: Double, lowDb: Double, hiss: Double) {
        var x = [Double](repeating: 0, count: win)
        vDSP_vmulD(seg, 1, hamming, 1, &x, 1, vDSP_Length(win))
        let m2 = power(x)
        var total = 0.0, low = 0.0, high = 0.0
        vDSP_sveD(m2, 1, &total, vDSP_Length(m2.count))
        m2.withUnsafeBufferPointer { p in
            vDSP_sveD(p.baseAddress! + lowBand.lowerBound, 1, &low, vDSP_Length(lowBand.count))
            vDSP_sveD(p.baseAddress! + hissBin, 1, &high, vDSP_Length(m2.count - hissBin))
        }
        let n = Double(win)
        return (10 * log10(total / n + 1e-12), 10 * log10(low / n + 1e-12), high / (total + 1e-12))
    }

    /// Peak of the normalised autocorrelation over 75–400 Hz pitch lags.
    private func voicing(_ seg: [Double]) -> Double {
        var mean = 0.0
        vDSP_meanvD(seg, 1, &mean, vDSP_Length(seg.count))
        var s = [Double](repeating: 0, count: seg.count)
        var negMean = -mean
        vDSP_vsaddD(seg, 1, &negMean, &s, 1, vDSP_Length(seg.count))
        let ac = Self.autocorrelation(s, lags: lagHi)
        guard ac[0] > 0 else { return 0 }
        return ac[lagLo..<lagHi].max()! / ac[0]
    }

    /// F1 and F2 from the peaks of the LPC envelope (no polynomial roots needed).
    private func formants(_ seg: [Double]) -> (f1: Double, f2: Double)? {
        var emph = [Double](repeating: 0, count: win)
        emph[0] = seg[0]
        for i in 1..<win { emph[i] = seg[i] - 0.97 * seg[i - 1] }
        var y = [Double](repeating: 0, count: win)
        vDSP_vmulD(emph, 1, hamming, 1, &y, 1, vDSP_Length(win))
        let r = Self.autocorrelation(y, lags: order + 1)
        guard r[0] > 1e-10 else { return nil }
        // Levinson-Durbin
        var a = [Double](repeating: 0, count: order + 1)
        a[0] = 1
        var e = r[0]
        for i in 1...order {
            var acc = r[i]
            for j in 1..<i { acc += a[j] * r[i - j] }
            let k = -acc / e
            let prev = a
            for j in 1..<i { a[j] = prev[j] + k * prev[i - j] }
            a[i] = k
            e *= 1 - k * k
            if e <= 0 { return nil }
        }
        // envelope 1/|A|^2 in dB, peak-picked
        let env = power(a).map { -10 * log10($0 + 1e-20) }
        let df = sampleRate / Double(nfft)
        var found: [Double] = []
        for k in max(1, formantLo)..<min(env.count - 1, formantHi + 1) {
            guard env[k] > env[k - 1] && env[k] >= env[k + 1] else { continue }
            let den = env[k - 1] - 2 * env[k] + env[k + 1]
            let d = den < 0 ? 0.5 * (env[k - 1] - env[k + 1]) / den : 0
            let f = (Double(k) + d) * df
            guard f > 200 && f < 3600 else { continue }
            if Self.bandwidth(env, k) * df < 400 { found.append(f) }
            if found.count == 2 { break }
        }
        return found.count == 2 ? (found[0], found[1]) : nil
    }

    /// -3 dB width of the envelope peak at bin `k`, in bins. A side that turns upward again before
    /// dropping 3 dB doesn't count; with neither side resolved the peak is too broad to be a formant.
    private static func bandwidth(_ env: [Double], _ k: Int) -> Double {
        let top = env[k] - 3
        var sides: [Double] = []
        for step in [-1, 1] {
            var j = k
            while j > 0 && j < env.count - 1 {
                let nj = j + step
                if env[nj] <= top {
                    sides.append(Double(abs(j - k)) + (env[j] - top) / (env[j] - env[nj]))
                    break
                }
                if env[nj] > env[j] { break }
                j = nj
            }
        }
        if sides.isEmpty { return .infinity }
        return sides.count == 2 ? sides[0] + sides[1] : 2 * sides[0]
    }

    /// |DFT|^2 of `x` zero-padded to `nfft`, bins 0...nfft/2 (numpy's rfft scale).
    private func power(_ x: [Double]) -> [Double] {
        let half = nfft / 2
        var input = [Double](repeating: 0, count: nfft)
        input.replaceSubrange(0..<x.count, with: x)
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
        var m2 = [Double](repeating: 0, count: half + 1)
        m2[0] = re[0] * re[0] / 4
        m2[half] = im[0] * im[0] / 4
        for k in 1..<half { m2[k] = (re[k] * re[k] + im[k] * im[k]) / 4 }
        return m2
    }

    /// r[k] = sum over n of x[n] * x[n + k], for k in 0..<lags.
    private static func autocorrelation(_ x: [Double], lags: Int) -> [Double] {
        let padded = x + [Double](repeating: 0, count: lags)
        var out = [Double](repeating: 0, count: lags)
        vDSP_convD(padded, 1, x, 1, &out, 1, vDSP_Length(lags), vDSP_Length(x.count))
        return out
    }

    // MARK: - Small helpers

    /// Exponentially weighted mean and std, weight `w` for the new sample.
    private static func update(_ mean: Double, _ std: Double, _ x: Double, _ w: Double) -> (Double, Double) {
        let d = x - mean
        return (mean + w * d, ((1 - w) * (std * std + w * d * d)).squareRoot())
    }

    private static func sigmoid(_ x: Double) -> Double { 1 / (1 + exp(-min(60, max(-60, x)))) }

    private static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    private static func median(_ v: [Double]) -> Double {
        let s = v.sorted(), m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    /// Second-order follower: semi-implicit Euler, two 5 ms substeps per hop. Opens and closes can
    /// run at different speeds.
    private struct Spring {
        let up: Double, down: Double, zeta: Double
        var x = 0.0, v = 0.0

        init(up: Double, down: Double, zeta: Double) { self.up = up; self.down = down; self.zeta = zeta }

        mutating func step(_ target: Double, _ dt: Double) -> Double {
            let w0 = 2 * Double.pi * (target > x ? up : down)
            let h = dt / 2
            for _ in 0..<2 {
                v += (w0 * w0 * (target - x) - 2 * zeta * w0 * v) * h
                x += v * h
            }
            return x
        }
    }
}
