import Testing
import Foundation

/// The live mouth reader against its Python reference (tools/mouth/reader_live.py). Both build the
/// same synthetic signal (formant-synthesised a/i/u vowels and s noise); the Python wrote what it read
/// to Fixtures/mouth_reader_synth.json and the Swift port must read the same.
struct MouthReaderTests {
    static let segments: [(name: String, duration: Double)] = [
        ("sil", 0.30), ("a", 0.40), ("s", 0.16), ("i", 0.40), ("sil", 0.30), ("u", 0.40), ("s", 0.16),
        ("a", 0.36), ("sil", 0.40), ("i", 0.36), ("u", 0.40), ("sil", 0.30),
    ]
    static let vowels: [String: [Double]] = [
        "a": [730, 1090, 2440], "i": [270, 2290, 3010], "u": [300, 870, 2240],
    ]

    /// Mirror of `synth()` in reader_live.py: an impulse train through three formant resonators for
    /// vowels, LCG noise for s, a faint noise floor under everything. Same arithmetic, same order.
    static func synth(sampleRate sr: Double = 16_000) -> [Float] {
        var out: [Double] = []
        var seed: Int64 = 12345
        var phase = 0.0
        let f0 = 120.0
        for (name, duration) in segments {
            let n = Int((duration * sr).rounded())
            let ramp = Int(0.015 * sr)
            var resonators: [[Double]] = []
            if let formants = vowels[name] {
                for (f, bw) in zip(formants, [80.0, 100.0, 120.0]) {
                    let r = exp(-Double.pi * bw / sr)
                    let a1 = 2.0 * r * cos(2.0 * Double.pi * f / sr), a2 = -r * r
                    resonators.append([1.0 - a1 - a2, a1, a2, 0.0, 0.0])
                }
            }
            for i in 0..<n {
                if name == "sil" { out.append(0); continue }
                let g = min(1.0, Double(i) / Double(ramp), Double(n - 1 - i) / Double(ramp))
                if !resonators.isEmpty {
                    phase += f0 / sr
                    var x = 0.0
                    if phase >= 1.0 { phase -= 1.0; x = 1.0 }
                    for q in resonators.indices {
                        let y = resonators[q][0] * x + resonators[q][1] * resonators[q][3] + resonators[q][2] * resonators[q][4]
                        resonators[q][4] = resonators[q][3]; resonators[q][3] = y; x = y
                    }
                    out.append(0.5 * g * x)
                } else {
                    seed = (seed * 1_103_515_245 + 12345) % 2_147_483_648
                    out.append(0.03 * g * (Double(seed) / 1_073_741_824.0 - 1.0))
                }
            }
        }
        for i in out.indices {
            seed = (seed * 1_103_515_245 + 12345) % 2_147_483_648
            out[i] += 0.0005 * (Double(seed) / 1_073_741_824.0 - 1.0)
        }
        return out.map { Float($0) }
    }

    private struct Fixture {
        let samples: Int, sampleSum: Double, sampleAbsSum: Double
        let frames: [MouthFrame]
    }

    private func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mouth_reader_synth.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let rows = try #require(json["frames"] as? [[Double]])
        return Fixture(samples: try #require(json["samples"] as? Int),
                       sampleSum: try #require(json["sampleSum"] as? Double),
                       sampleAbsSum: try #require(json["sampleAbsSum"] as? Double),
                       frames: rows.map { MouthFrame(t: $0[0], J: Float($0[1]), W: Float($0[2]), T: Float($0[3]), speaking: $0[4] != 0) })
    }

    /// Feeds `samples` in chunks of the given sizes, cycling through them.
    private func read(_ samples: [Float], chunks: [Int] = [250], stats: SpeakerStats? = nil) -> (MouthReader, [MouthFrame]) {
        let reader = MouthReader(sampleRate: 16_000, stats: stats)
        var frames: [MouthFrame] = []
        var i = 0, c = 0
        while i < samples.count {
            let end = min(samples.count, i + chunks[c % chunks.count])
            frames += reader.feed(Array(samples[i..<end]))
            i = end; c += 1
        }
        return (reader, frames)
    }

    @Test func syntheticSignalMatchesPython() throws {
        let fx = try fixture()
        let x = Self.synth()
        #expect(x.count == fx.samples)
        #expect(abs(x.reduce(0.0) { $0 + Double($1) } - fx.sampleSum) < 1e-3)
        #expect(abs(x.reduce(0.0) { $0 + abs(Double($1)) } - fx.sampleAbsSum) < 1e-2)
    }

    @Test func framesMatchPythonReference() throws {
        let fx = try fixture()
        let (_, frames) = read(Self.synth())
        try #require(frames.count == fx.frames.count)
        var worst: Float = 0, gateMismatches = 0
        for (s, p) in zip(frames, fx.frames) {
            #expect(abs(s.t - p.t) < 1e-4)
            worst = max(worst, abs(s.J - p.J), abs(s.W - p.W), abs(s.T - p.T))
            if s.speaking != p.speaking { gateMismatches += 1 }
        }
        #expect(worst < 0.01, "largest J/W/T difference from Python: \(worst)")
        #expect(gateMismatches == 0)
    }

    @Test func vowelsComeOutRight() {
        let (_, frames) = read(Self.synth())
        var start = 0.0
        for (name, duration) in Self.segments {
            // skip the first 120 ms of each segment: springs settling, the gate's hangover, the fade
            let lo = start + min(0.12, 0.4 * duration), hi = start + duration
            start = hi
            let seg = frames.filter { $0.t >= lo && $0.t <= hi }
            let n = Float(seg.count)
            let J = seg.reduce(0) { $0 + $1.J } / n, W = seg.reduce(0) { $0 + $1.W } / n, T = seg.reduce(0) { $0 + $1.T } / n
            let label = "\(name) at \(String(format: "%.2f", lo))s: J \(J) W \(W) T \(T)"
            switch name {
            case "a": #expect(J > 0.6 && abs(W) < 0.3, "ah should open the jaw wide, lips neutral; \(label)")
            case "i": #expect(W > 0.6, "ee should spread the lips; \(label)")
            case "u": #expect(W < -0.6, "oo should pucker; \(label)")
            case "s": #expect(T > 0.6 && J < 0.45, "s should bring the teeth together; \(label)")
            default:  #expect(seg.allSatisfy { !$0.speaking } && J < 0.15, "silence should rest; \(label)")
            }
        }
    }

    @Test func chunkSizeDoesNotChangeTheOutput() {
        let x = Self.synth()
        let (_, whole) = read(x, chunks: [x.count])
        let (_, ragged) = read(x, chunks: [1, 7, 160, 333, 4096, 399])
        #expect(whole == ragged)
    }

    @Test func statsAdaptAndRoundTrip() throws {
        let (reader, _) = read(Self.synth())
        let learned = reader.stats
        #expect(learned.weight > SpeakerStats.typical.weight)
        #expect(learned.f2Mean != SpeakerStats.typical.f2Mean)
        #expect(learned.floorDb < -45)      // the synthetic floor is about -51 dB
        let decoded = try JSONDecoder().decode(SpeakerStats.self, from: JSONEncoder().encode(learned))
        #expect(decoded == learned)
        #expect(MouthReader(stats: decoded).stats == learned)
    }
}
