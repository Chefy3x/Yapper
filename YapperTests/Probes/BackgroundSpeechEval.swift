import Testing
import Foundation
import FluidAudio

/// Opt-in: the background-speech gate replayed over the user's own saved dictations, oldest
/// first, exactly as the app runs it: the voice print starts empty and learns from each
/// dictation after it is transcribed. YAPPER_BG_EVAL=<Yapper's Application Support folder>,
/// YAPPER_BG_EVAL_N=<most recent recordings, default all>. Prints every recording the gate
/// changes and the lowest voice scores among the suspect runs it kept. The recordings are the
/// user's own words, so nothing is written anywhere.
struct BackgroundSpeechEval {
    static let path = ProcessInfo.processInfo.environment["YAPPER_BG_EVAL"]
    static let sample = Int(ProcessInfo.processInfo.environment["YAPPER_BG_EVAL_N"] ?? "") ?? .max

    private func files() throws -> [URL] {
        guard let path = Self.path else { return [] }
        let base = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: base.appendingPathComponent("dictations.json"))
        let json = try JSONSerialization.jsonObject(with: data)
        let rows = (json as? [[String: Any]]) ?? ((json as? [String: Any])?["dictations"] as? [[String: Any]]) ?? []
        return rows
            .compactMap { row -> (String, String)? in
                guard let file = row["audioFileName"] as? String else { return nil }
                return ("\(row["at"] ?? "")", file)
            }
            .sorted { $0.0 < $1.0 }
            .suffix(Self.sample)
            .map { base.appendingPathComponent("Dictations").appendingPathComponent($0.1) }
    }

    @Test(.enabled(if: path != nil)) func replayOnSavedDictations() async throws {
        let files = try files()
        let asr = try await AsrModels.downloadAndLoad(version: ParakeetTranscriber.version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(asr)
        let speaker = try await SpeakerEmbedder.load()
        let converter = AudioConverter()

        var voice = VoicePrint(model: SpeakerEmbedder.model)
        var heard = 0, changed = 0, dropped = 0, total = 0, suspects = 0
        var keptScores: [Float] = []
        for url in files {
            guard let samples = try? converter.resampleAudioFile(path: url.path), samples.count > 8_000 else { continue }
            var state = TdtDecoderState.make(decoderLayers: ParakeetTranscriber.version.decoderLayers)
            let result = try await manager.transcribe(samples, decoderState: &state)
            let words = buildWordTimings(from: result.tokenTimings ?? [])
                .map { BackgroundSpeechGate.Word(text: $0.word, start: $0.startTime, end: $0.endTime) }
            let levels = BackgroundSpeechGate.levels(of: words, samples: samples)
            heard += 1
            total += words.count
            let id = url.lastPathComponent.prefix(8)

            if voice.isReady {
                let current = voice
                var scores: [(String, Float)] = []
                let gated = BackgroundSpeechGate.keptWords(words, levels: levels, samples: samples) { audio in
                    let score = speaker.embed(audio).flatMap(current.similarity)
                    if let score { scores.append((String(format: "%.1fs", Double(audio.count) / 16_000), score)) }
                    return score
                }
                suspects += scores.count
                for (_, score) in scores where score >= BackgroundSpeechGate.voiceMatchMin { keptScores.append(score) }
                if gated.dropped > 0 {
                    changed += 1
                    dropped += gated.dropped
                    print("EVAL ---- \(id) dropped \(gated.dropped)/\(words.count), runs \(scores.map { "\($0.0) \(String(format: "%.2f", $0.1))" })")
                    print("EVAL  before: \(result.text)")
                    print("EVAL  after:  \(BackgroundSpeechGate.text(gated.words))")
                }
            }

            // The app's learning step, verbatim.
            let loud = BackgroundSpeechGate.loudWords(levels: levels).map { words[$0] }
            let audio = BackgroundSpeechGate.audio(of: loud, in: samples)
            guard Double(audio.count) / 16_000 >= VoicePrint.minLearnSeconds, let embedding = speaker.embed(audio) else { continue }
            voice.learn(embedding)
        }
        keptScores.sort()
        print("EVAL ==== \(heard) recordings, \(changed) changed, \(dropped)/\(total) words dropped; \(suspects) suspect runs checked")
        print("EVAL lowest kept suspect scores: \(keptScores.prefix(8).map { String(format: "%.2f", $0) })")
        print("EVAL voice print learned from \(voice.count)")
    }
}
