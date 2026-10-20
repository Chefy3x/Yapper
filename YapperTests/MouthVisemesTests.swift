import Testing
import Foundation

/// The viseme net against its Python reference (`Stream` in tools/mouth/visemes.py). Both read the
/// reader's synthetic a/i/u/s signal through the bundled weights; the Python wrote its log-mel bands
/// and shapes to Fixtures/mouth_visemes_synth.json (regenerate it with `visemes.py fixture` after
/// retraining) and the Swift port must read the same.
struct MouthVisemesTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    static func model() throws -> MouthVisemeModel {
        try MouthVisemeModel(data: Data(contentsOf: repo.appendingPathComponent("Yapper/Resources/visemes.bin")))
    }

    private struct Fixture {
        var samples: Int, hops: Int, lookahead: Int
        var logMelRows: [Int], logMel: [[Double]]
        var probs: [[Float]]
        var classes: [String]
    }

    private func fixture() throws -> Fixture {
        let url = Self.repo.appendingPathComponent("YapperTests/Fixtures/mouth_visemes_synth.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return Fixture(samples: try #require(json["samples"] as? Int), hops: try #require(json["hops"] as? Int),
                       lookahead: try #require(json["lookahead"] as? Int),
                       logMelRows: try #require(json["logMelRows"] as? [Int]),
                       logMel: try #require(json["logMel"] as? [[Double]]),
                       probs: try #require(json["probs"] as? [[Double]]).map { $0.map(Float.init) },
                       classes: try #require(json["classes"] as? [String]))
    }

    /// Feeds `samples` in chunks of the given sizes, cycling through them.
    private func read(_ v: MouthVisemes, _ samples: [Float], chunks: [Int] = [250]) -> [MouthShapes?] {
        var out: [MouthShapes?] = []
        var i = 0, c = 0
        while i < samples.count {
            let end = min(samples.count, i + chunks[c % chunks.count])
            out += v.feed(Array(samples[i..<end]))
            i = end; c += 1
        }
        return out
    }

    @Test func modelLoads() throws {
        let m = try Self.model()
        let fx = try fixture()
        #expect(m.header.classes == fx.classes)
        #expect(m.header.classes.count == MouthShape.allCases.count)
        #expect(m.lookahead == fx.lookahead)
        #expect(m.lookahead <= 4, "the shapes must arrive inside MouthTimeline's 45 ms playout")
        let weights = m.layers.reduce(0) { $0 + $1.weights.count + $1.bias.count } + m.outWeights.count + m.outBias.count
        #expect(weights < 1_000_000)
    }

    @Test func logMelMatchesPython() throws {
        let fx = try fixture()
        let v = MouthVisemes(model: try Self.model())
        let x = MouthReaderTests.synth().map(Double.init)
        let h = v.model.header
        #expect(x.count == fx.samples)
        for (row, want) in zip(fx.logMelRows, fx.logMel) {
            let got = v.logMel(Array(x[(row * h.hop)..<(row * h.hop + h.win)]))
            let worst = zip(got, want).map { abs($0 - $1) }.max()!
            #expect(worst < 1e-3, "hop \(row): largest log-mel difference \(worst)")
        }
    }

    @Test func shapesMatchPython() throws {
        let fx = try fixture()
        let v = MouthVisemes(model: try Self.model())
        let out = read(v, MouthReaderTests.synth())
        #expect(out.count == fx.hops)
        #expect(out.prefix(fx.lookahead).allSatisfy { $0 == nil })
        let shapes = out.compactMap { $0 }
        try #require(shapes.count == fx.probs.count)
        var worst: Float = 0, argmaxMismatches = 0
        for (s, p) in zip(shapes, fx.probs) {
            for i in p.indices { worst = max(worst, abs(s[i] - p[i])) }
            let a = (0..<p.count).max { s[$0] < s[$1] }!, b = p.indices.max { p[$0] < p[$1] }!
            if a != b { argmaxMismatches += 1 }
            #expect(abs((0..<p.count).reduce(Float(0)) { $0 + s[$1] } - 1) < 1e-4)
        }
        #expect(worst < 2e-3, "largest probability difference from Python: \(worst)")
        #expect(argmaxMismatches == 0)
    }

    @Test func soundsComeOutAsTheirShapes() throws {
        let v = MouthVisemes(model: try Self.model())
        let shapes = read(v, MouthReaderTests.synth()).compactMap { $0 }
        // hop i's window centre is at (160 i + 200) / 16000 s
        var start = 0.0
        for (name, duration) in MouthReaderTests.segments {
            let lo = start + min(0.06, 0.3 * duration), hi = start + duration - 0.04
            start += duration
            let seg = shapes.indices.filter { let t = (Double($0) * 160 + 200) / 16_000; return t >= lo && t <= hi }.map { shapes[$0] }
            let mean = seg.reduce(MouthShapes()) { $0 + $1 } / Float(seg.count)
            func p(_ s: MouthShape) -> Float { mean[s.rawValue] }
            let label = "\(name): " + MouthShape.allCases.map { "\($0) \(String(format: "%.2f", p($0)))" }.joined(separator: " ")
            // The synthetic a (F1 730, F2 1090) sits on the ah/oh line, and the s is white noise, which
            // is as much an f as an s: both count as open, and as a hiss, either way.
            switch name {
            case "a": #expect(p(.ah) + p(.oh) > 0.5, "\(label)")
            case "i": #expect(p(.ee) > 0.5, "\(label)")
            case "u": #expect(p(.oo) + p(.oh) > 0.5, "\(label)")
            case "s": #expect(p(.teeth) + p(.sh) + p(.fv) > 0.4, "\(label)")
            default:  #expect(p(.rest) > 0.5, "\(label)")
            }
        }
    }

    @Test func chunkSizeDoesNotChangeTheOutput() throws {
        let m = try Self.model()
        let x = MouthReaderTests.synth()
        let whole = read(MouthVisemes(model: m), x, chunks: [x.count])
        let ragged = read(MouthVisemes(model: m), x, chunks: [1, 7, 160, 333, 4096, 399])
        #expect(whole == ragged)
    }

    @Test func resetClearsTheLayersButKeepsTheMean() throws {
        let v = MouthVisemes(model: try Self.model())
        let x = MouthReaderTests.synth()
        _ = read(v, x)
        let mean = v.mean
        #expect(mean != v.model.mean0)
        v.reset()
        #expect(v.mean == mean)
        #expect(read(v, Array(x.prefix(2000))).prefix(v.lookahead).allSatisfy { $0 == nil })
    }

    @Test func timelinePutsShapesBackWhereTheyBelong() {
        // drive k carries the shape for drive k - 4; shape i is one-hot on class i % 10
        func oneHot(_ i: Int) -> MouthShapes { var s = MouthShapes(); s[i % 10] = 1; return s }
        var timeline = MouthTimeline()
        var made: [MouthDrive] = []
        for k in 0..<40 { made.append(MouthDrive(J: Float(k) / 40, shape: k >= 4 ? oneHot(k - 4) : MouthShapes())) }
        timeline.add(made, at: 1.0, shapeLag: 4)
        let stamps = timeline.drives.map(\.t)
        #expect(timeline.drives.allSatisfy { !$0.d.hasShape })
        #expect(timeline.shapes.count == 36)
        for (i, s) in timeline.shapes.enumerated() {
            #expect(s.t == stamps[i])
            #expect(s.s == oneHot(i))
        }
        // a moment past the newest shape holds it; the drive there is still the newest drive's
        let d = timeline.drive(at: stamps[39] + MouthTimeline.playout)
        #expect(d.J == made[39].J)
        #expect(d.shape == oneHot(35))
        // with no net, no shape
        var plain = MouthTimeline()
        plain.add(made.map { MouthDrive(J: $0.J) }, at: 1.0)
        #expect(!plain.drive(at: 1.0).hasShape)
    }

    @Test func shaperSealsAndHoldsAQuickM() {
        var shaper = MouthShaper()
        var m = MouthShapes(); m[MouthShape.mbp.rawValue] = 0.9; m[MouthShape.ah.rawValue] = 0.1
        var ah = MouthShapes(); ah[MouthShape.ah.rawValue] = 1
        var oo = MouthShapes(); oo[MouthShape.oo.rawValue] = 1
        let dt: Float = 1 / 120
        var peak: Float = 0, t: Float = 0
        // ah, a 30 ms m, ah again: the seal still lands
        while t < 0.4 {
            let s = t >= 0.1 && t < 0.13 ? m : ah
            peak = max(peak, shaper.step(s, dt: dt).close)
            t += dt
        }
        #expect(peak > 0.8, "a quick m should still seal the lips: \(peak)")
        // oo rounds (negative width), ee spreads
        var w: Float = 0
        for _ in 0..<60 { w = shaper.step(oo, dt: dt).W }
        #expect(w < -0.9)
        var pose = MouthPose(J: 0.5)
        MouthShaper.apply(close: 1, fv: 0, part: 0, to: &pose)
        #expect(pose.close == 1 && pose.J < 0.5)
    }
}
