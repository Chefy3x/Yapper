import Accelerate
import CoreML
import Foundation

/// What the mouth's ear does: 16 kHz mono in, one `MouthShapes` per 10 ms hop out, `lookahead` hops
/// after that hop was heard. `MouthVisemes` (the small net) and `MouthWavLM` both are one.
protocol MouthEar: AnyObject {
    /// Hops between hearing a hop and knowing its shape.
    var lookahead: Int { get }
    /// One entry per completed hop: the shapes for the hop `lookahead` hops back, or nil while it fills.
    func feed(_ samples: UnsafeBufferPointer<Float>) -> [MouthShapes?]
    func reset()
}

extension MouthEar {
    func feed(_ samples: [Float]) -> [MouthShapes?] { samples.withUnsafeBufferPointer { feed($0) } }
}

extension MouthVisemes: MouthEar {}

/// The small layer that reads WavLM's frames as mouth shapes, one per lookahead, written by
/// `pretrained_ear.py export-head`. File layout: "MWAV", UInt32 version, UInt32 header length, the
/// JSON header, then little-endian float32: the input mean and spread (768 each), the hidden layer's
/// weights (hidden, 768) and bias, the output layer's weights (classes, hidden) and bias.
struct MouthWavLMHead: Sendable {
    struct Header: Decodable, Sendable {
        /// 20 ms frames heard ahead of the newest frame it answers for.
        var lookahead: Int
        var features: Int, hidden: Int
        var classes: [String]
        /// The encoder this head reads, when it was trained with WavLM's top layers tuned to the user's
        /// voice; nil for the shared `MouthWavLM.encoderName`.
        var encoder: String?
    }
    let header: Header
    let mean: [Float], spread: [Float]
    let w1: [Float], b1: [Float], w2: [Float], b2: [Float]
    enum LoadError: Error { case notAHead, missing }

    init(data: Data) throws {
        guard data.count > 12, data.prefix(4) == Data("MWAV".utf8) else { throw LoadError.notAHead }
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
        let F = header.features, H = header.hidden, C = header.classes.count
        mean = try take(F); spread = try take(F)
        w1 = try take(H * F); b1 = try take(H)
        w2 = try take(C * H); b2 = try take(C)
        guard at == floats.count else { throw LoadError.missing }
    }

    /// One frame's 768 features → shape probabilities in `MouthShape` order.
    func shapes(_ x: UnsafePointer<Float>) -> MouthShapes {
        let F = header.features, H = header.hidden, C = header.classes.count
        var z = [Float](repeating: 0, count: F)
        vDSP_vsub(mean, 1, x, 1, &z, 1, vDSP_Length(F))                 // x - mean
        vDSP_vdiv(spread, 1, z, 1, &z, 1, vDSP_Length(F))               // / spread
        var h = b1
        cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(H), Int32(F), 1, w1, Int32(F), z, 1, 1, &h, 1)
        for o in 0..<H { let v = h[o]; h[o] = 0.5 * v * (1 + erff(v / 1.41421356)) }   // GELU
        var logits = b2
        cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(C), Int32(H), 1, w2, Int32(H), h, 1, 1, &logits, 1)
        let top = logits.max() ?? 0
        let e = logits.map { expf($0 - top) }, sum = e.reduce(0, +)
        var out = MouthShapes()
        for c in 0..<min(C, MouthShape.allCases.count) { out[c] = e[c] / sum }
        return out
    }
}

/// The mouth's ear on Microsoft's WavLM (base+, MIT): a speech model that already tells sounds apart,
/// run on the Neural Engine. Every 20 ms it hears the last 0.765 s and answers for the newest 20 ms
/// frame it has heard `head.lookahead` frames past. `pretrained_ear.py` trained the head answering every
/// 40 ms (`frames_multi`); every 20 ms scored within a point of it on the user's test dictations
/// (82.3% vs 83.4% of sounds) and runs the mouth 20 ms sooner. The encoder (WavLMEar.mlmodelc) and the heads (<name>.wavlm) aren't bundled:
/// they live in `folder`, and without them the app falls back to the small net. A head can name its own
/// encoder (one tuned with it), which then loads in place of the shared one.
final class MouthWavLM: MouthEar {
    static let pastFrames = 30, stepFrames = 1
    static let windowFrames = 38
    static let windowSamples = windowFrames * 320 + 80
    static let encoderName = "WavLMEar.mlmodelc"
    /// The heads Settings offers, by how far ahead they hear: 40 ms is the one in use, 80 ms (later,
    /// but surer) is kept to try. `earKey` names the pick.
    static let heads = ["WavLM 40", "WavLM 80"]
    static let earKey = "mouthEar"
    static var chosenHead: String {
        let name = UserDefaults.standard.string(forKey: earKey) ?? ""
        return heads.contains(name) ? name : heads[0]
    }
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Yapper/Mouth", isDirectory: true)
    }

    let head: MouthWavLMHead
    let encoder: Encoder
    /// Every sample since the last reset that a window may still need, oldest first.
    private var audio: [Float] = []
    private var dropped = 0                 // samples discarded from the front of `audio`
    private var heard = 0                   // samples fed since reset
    private var hopsOut = 0                 // hops reported so far
    private var nextEnd: Int                // the next window's end, in 20 ms frames
    private var known: [Int: MouthShapes] = [:]   // hop → shapes, waiting to be reported

    /// The hop lag: two hops a frame heard ahead, the wait for the next window, and one spare.
    var lookahead: Int { Self.lookahead(head.header.lookahead) }
    static func lookahead(_ frames: Int) -> Int { 2 * frames + 2 * stepFrames - 1 }

    /// The head called `name` and its encoder, when both are in `folder`.
    private static func load(_ name: String) -> (head: MouthWavLMHead, encoder: String)? {
        guard let head = try? MouthWavLMHead(data: Data(contentsOf: folder.appendingPathComponent(name + ".wavlm"))) else { return nil }
        let encoder = head.header.encoder ?? encoderName
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(encoder).path) ? (head, encoder) : nil
    }

    /// Whether the picked head and its encoder are both in `folder`.
    static var isInstalled: Bool { load(chosenHead) != nil }

    /// The picked ear, on its encoder (loading in the background if it isn't yet: the mouth's own
    /// shapes are simply missing until it is), or nil when it isn't installed.
    static func installed() -> MouthWavLM? {
        load(chosenHead).map { MouthWavLM(head: $0.head, encoder: Encoder.named($0.encoder)) }
    }

    /// The heads in `heads` that are installed and load, with how many hops ahead each hears.
    static func installedHeads() -> [(name: String, lookahead: Int)] {
        heads.compactMap { name in load(name).map { (name, lookahead($0.head.header.lookahead)) } }
    }

    /// A WavLM encoder, loaded once and shared by every head that reads it. The first load on a Mac compiles it for
    /// the Neural Engine, which took ~45 s; done on the mouth's queue, that froze the mouth for as long.
    /// So it loads on its own queue and `model` is nil until it's ready.
    final class Encoder: @unchecked Sendable {
        private static let made = NSLock()
        nonisolated(unsafe) private static var byName: [String: Encoder] = [:]
        /// The one encoder for the file `name` in `folder`.
        static func named(_ name: String) -> Encoder {
            made.lock(); defer { made.unlock() }
            if let e = byName[name] { return e }
            let e = Encoder(url: folder.appendingPathComponent(name)); byName[name] = e
            return e
        }
        private let url: URL
        private let lock = NSLock()
        private var loaded: MLModel?
        private var started = false
        init(url: URL) { self.url = url }

        var model: MLModel? { lock.lock(); defer { lock.unlock() }; return loaded }

        func prepare() {
            lock.lock(); defer { lock.unlock() }
            guard !started else { return }
            started = true
            DispatchQueue.global(qos: .utility).async { [self] in
                let cfg = MLModelConfiguration()
                cfg.computeUnits = .cpuAndNeuralEngine
                let m = try? MLModel(contentsOf: url, configuration: cfg)
                lock.lock(); loaded = m; if m == nil { started = false }; lock.unlock()
            }
        }

        /// Loads now, on the caller's thread (tests and probes).
        func loadNow() throws -> MLModel {
            if let m = model { return m }
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .cpuAndNeuralEngine
            let m = try MLModel(contentsOf: url, configuration: cfg)
            lock.lock(); loaded = m; started = true; lock.unlock()
            return m
        }
    }

    init(head: MouthWavLMHead, encoder: Encoder) {
        self.head = head
        self.encoder = encoder
        encoder.prepare()
        nextEnd = Self.stepFrames
    }

    func reset() {
        audio = []; dropped = 0; heard = 0; hopsOut = 0; nextEnd = Self.stepFrames; known = [:]
    }

    func feed(_ samples: UnsafeBufferPointer<Float>) -> [MouthShapes?] {
        audio.append(contentsOf: samples)
        heard += samples.count
        // every window whose audio is now all in: it ends at frame e, needing samples up to e * 320 + 80
        while nextEnd * 320 + 80 <= heard {
            run(end: nextEnd)
            nextEnd += Self.stepFrames
        }
        // keep only what the next window can reach
        let keepFrom = (nextEnd - Self.windowFrames) * 320
        if keepFrom - dropped > 16_000 {
            let cut = keepFrom - dropped
            audio.removeFirst(cut); dropped += cut
        }
        // hops the reader has finished (a 400-sample window every 160), each answered `lookahead` hops late
        let done = heard >= 400 ? (heard - 400) / 160 + 1 : 0
        var out: [MouthShapes?] = []
        while hopsOut < done {
            let h = hopsOut - lookahead
            out.append(h >= 0 ? (known.removeValue(forKey: h) ?? MouthShapes()) : nil)
            hopsOut += 1
        }
        return out
    }

    /// One window ending at frame `e`: its features, and the shapes for frames [e - la - 2, e - la).
    private func run(end e: Int) {
        guard let model = encoder.model else { return }     // still loading: no shapes for these frames
        let start = (e - Self.windowFrames) * 320           // may be before the first sample: silence there
        var w = [Float](repeating: 0, count: Self.windowSamples)
        let from = max(0, start - dropped), to = min(audio.count, start - dropped + Self.windowSamples)
        if to > from { audio.withUnsafeBufferPointer { a in w.withUnsafeMutableBufferPointer { d in
            (d.baseAddress! + (from - (start - dropped))).update(from: a.baseAddress! + from, count: to - from)
        } } }
        // zero mean, unit spread, as WavLM was fed in training
        var mu: Float = 0, sd: Float = 0
        vDSP_normalize(w, 1, nil, 1, &mu, &sd, vDSP_Length(w.count))
        guard let input = try? MLMultiArray(shape: [1, NSNumber(value: Self.windowSamples)], dataType: .float32) else { return }
        var negMu = -mu, inv = 1 / (sd + 1e-7)
        vDSP_vsadd(w, 1, &negMu, input.dataPointer.assumingMemoryBound(to: Float.self), 1, vDSP_Length(w.count))
        vDSP_vsmul(input.dataPointer.assumingMemoryBound(to: Float.self), 1, &inv, input.dataPointer.assumingMemoryBound(to: Float.self), 1, vDSP_Length(w.count))
        guard let result = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": input])),
              let frames = result.featureValue(for: "frames")?.multiArrayValue else { return }
        let la = head.header.lookahead, F = head.header.features
        let rs = frames.strides[1].intValue, cs = frames.strides[2].intValue
        var row = [Float](repeating: 0, count: F)
        for j in 0..<Self.stepFrames {
            let f = e - la - Self.stepFrames + j
            guard f >= 0 else { continue }
            let r = Self.windowFrames - la - Self.stepFrames + j
            switch frames.dataType {
            case .float16:
                #if arch(arm64)
                let p = frames.dataPointer.assumingMemoryBound(to: Float16.self)
                for i in 0..<F { row[i] = Float(p[r * rs + i * cs]) }
                #else
                // Swift has no Float16 on Intel; the array's own accessor converts (slower, rare).
                for i in 0..<F { row[i] = frames[[0, NSNumber(value: r), NSNumber(value: i)]].floatValue }
                #endif
            default:
                let p = frames.dataPointer.assumingMemoryBound(to: Float.self)
                for i in 0..<F { row[i] = p[r * rs + i * cs] }
            }
            let s = row.withUnsafeBufferPointer { head.shapes($0.baseAddress!) }
            known[2 * f] = s; known[2 * f + 1] = s
        }
    }
}
