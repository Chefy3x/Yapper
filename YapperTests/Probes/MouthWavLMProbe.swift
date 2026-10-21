import Testing
import Foundation

/// Opt-in: runs the WavLM ear (`MouthWavLM`) over a recording exactly as the app feeds it, 10 ms at a
/// time, and writes the shape it picks for each hop, one `MouthShape` index per line, to set against
/// tools/mouth/pretrained_ear.py on the same audio. YAPPER_WAVLM_PROBE=<wav>, with the ear installed in
/// `MouthWavLM.folder`; writes <wav>.hops.txt.
struct MouthWavLMProbe {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test(.enabled(if: env["YAPPER_WAVLM_PROBE"] != nil)) func probe() throws {
        let wav = URL(fileURLWithPath: Self.env["YAPPER_WAVLM_PROBE"]!)
        let loadStart = Date()
        let ear = try #require(MouthWavLM.installed())
        _ = try ear.encoder.loadNow()
        print("wavlm probe: load took \(Int(Date().timeIntervalSince(loadStart) * 1000)) ms")
        let audio = try MouthFilm.mono16k(wav)
        var hops: [MouthShapes?] = []
        let started = Date()
        for k in stride(from: 0, to: audio.count, by: 160) { hops += ear.feed(Array(audio[k..<min(audio.count, k + 160)])) }
        let took = Date().timeIntervalSince(started)
        // entry i answers for hop i - lookahead
        let shapes = hops.dropFirst(ear.lookahead).map { s in s.map { v in (0..<10).max { v[$0] < v[$1] }! } ?? 0 }
        try shapes.map(String.init).joined(separator: "\n").write(to: wav.appendingPathExtension("hops.txt"), atomically: true, encoding: .utf8)
        print("wavlm probe: \(shapes.count) hops, lookahead \(ear.lookahead) hops, \(Int(took * 1000)) ms for \(audio.count / 16) ms of audio")
    }
}
