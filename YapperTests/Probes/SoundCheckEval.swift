import Testing
import Foundation
import FluidAudio

/// Opt-in: the context check on the user's own kept dictations, before and after.
/// YAPPER_SOUND_EVAL=<labels.json>, YAPPER_SOUND_EVAL_N=<extra unlabelled recordings to check
/// for collateral changes, default 200>, YAPPER_CONTEXT_MODELS=<comma-separated .gguf paths to
/// compare, default the downloaded formatter>. Uses the vocabulary's real terms and `heardAs` hints.
///
/// labels.json maps a dictation id prefix to checks: `[want]` or `[want, mustNotContain]`. A
/// check passes when the final text contains `want` (any case) and not the second string.
/// Labels hold the user's own words, so they live outside the repo.
@MainActor
struct SoundCheckEval {
    nonisolated static let path = ProcessInfo.processInfo.environment["YAPPER_SOUND_EVAL"]
    nonisolated static let extra = Int(ProcessInfo.processInfo.environment["YAPPER_SOUND_EVAL_N"] ?? "") ?? 200
    nonisolated static let models = (ProcessInfo.processInfo.environment["YAPPER_CONTEXT_MODELS"] ?? "")
        .split(separator: ",").map { URL(fileURLWithPath: String($0)) }
    static let margins: [Double] = [0, 1, 2, 3, 4, 5, 6]

    struct Record: Decodable { let id: String; let audioFileName: String?; let duration: Double }

    struct Clip { let id: String; let audio: [Float]; let checks: [[String]] }

    private func clips() throws -> (labelled: [Clip], others: [Clip]) {
        guard let path = Self.path else { return ([], []) }
        let labels = try JSONDecoder().decode([String: [[String]]].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Yapper")
        let records = try JSONDecoder().decode([Record].self, from: Data(contentsOf: support.appendingPathComponent("dictations.json")))
        let converter = AudioConverter()
        func load(_ r: Record) -> [Float]? {
            guard let name = r.audioFileName else { return nil }
            let file = support.appendingPathComponent("Dictations").appendingPathComponent(name)
            return try? converter.resampleAudioFile(path: file.path)
        }
        var labelled: [Clip] = []
        for (prefix, checks) in labels {
            guard let r = records.first(where: { $0.id.hasPrefix(prefix) }), let audio = load(r) else {
                print("EVAL missing recording \(prefix)"); continue
            }
            labelled.append(Clip(id: prefix, audio: audio, checks: checks))
        }
        let pool = records.filter { r in r.duration >= 1.5 && r.duration <= 60 && !labels.keys.contains { r.id.hasPrefix($0) } }
        let step = max(1, pool.count / max(1, Self.extra))
        let others = stride(from: 0, to: pool.count, by: step).prefix(Self.extra).compactMap { i -> Clip? in
            load(pool[i]).map { Clip(id: String(pool[i].id.prefix(8)), audio: $0, checks: []) }
        }
        return (labelled.sorted { $0.id < $1.id }, others)
    }

    /// A transcript and the context check's verdict on each spot in it.
    struct Scored { let id: String; let text: String; let spots: [(SoundAlike, Double?)]; let checks: [[String]] }
    struct Heard { let id: String; let text: String; let checks: [[String]] }

    @Test(.enabled(if: path != nil)) func beforeAndAfter() async throws {
        let (labelled, others) = try clips()
        let vocabulary = VocabularyStore()
        let terms = vocabulary.terms
        print("EVAL \(labelled.count) labelled + \(others.count) other recordings; heard-as hints: \(vocabulary.heardAs)")

        let asr = try await AsrModels.downloadAndLoad(version: ParakeetTranscriber.version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(asr)

        func written(_ raw: String) -> String {
            let spoken = SpokenTimes.normalizeSpoken(raw)
            return NumberStyle.restrain(spoken: spoken, written: TextNormalizer.shared.normalizeSentence(spoken))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func finish(_ text: String) -> String {
            let corrected = TranscriptCorrector.apply(text, replacements: vocabulary.replacements)
            return TranscriptCorrector.respell(corrected, candidates: terms) { WordKnowledge.isDictionaryWord($0) }
        }
        func passes(_ text: String, _ check: [String]) -> Bool {
            let t = text.lowercased()
            return t.contains(check[0].lowercased()) && (check.count < 2 || !t.contains(check[1].lowercased()))
        }

        // Transcribe once; every model scores the same text.
        var heardLabelled: [Heard] = [], heardOthers: [Heard] = []
        for clip in labelled + others {
            var state = TdtDecoderState.make(decoderLayers: ParakeetTranscriber.version.decoderLayers)
            let h = Heard(id: clip.id, text: written(try await manager.transcribe(clip.audio, decoderState: &state).text), checks: clip.checks)
            if clip.checks.isEmpty { heardOthers.append(h) } else { heardLabelled.append(h) }
        }

        let modelURLs = Self.models.isEmpty ? [FormatterModel.fileURL] : Self.models
        for url in modelURLs {
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) / 1_000_000
            print("EVAL ===== \(url.lastPathComponent) (\(size) MB)")
            let runner = LlamaRunner(modelURL: url)
            let loadStart = Date()
            try await runner.load()
            let loadSeconds = Date().timeIntervalSince(loadStart)
            var times: [Double] = []
            func score(_ h: Heard) async -> Scored {
                var spots: [(SoundAlike, Double?)] = []
                for spot in SoundAlikes.spots(in: h.text, heardAs: vocabulary.heardAs, terms: terms).prefix(ContextCheck.maxQuestions) {
                    let t = Date()
                    spots.append((spot, await ContextCheck.advantage(runner, in: h.text, at: spot, terms: terms)))
                    times.append(Date().timeIntervalSince(t))
                }
                return Scored(id: h.id, text: h.text, spots: spots, checks: h.checks)
            }
            func output(_ s: Scored, margin: Double?) -> String {
                guard let margin else { return finish(s.text) }
                return finish(SoundAlikes.apply(s.spots.filter { ($0.1 ?? -.infinity) > margin }.map(\.0), to: s.text))
            }
            var scoredLabelled: [Scored] = []
            for h in heardLabelled { scoredLabelled.append(await score(h)) }
            var scoredOthers: [Scored] = []
            for h in heardOthers { scoredOthers.append(await score(h)) }

            if ProcessInfo.processInfo.environment["YAPPER_SOUND_EVAL_SPOTS"] != nil {
                for s in scoredLabelled + scoredOthers {
                    for (spot, adv) in s.spots {
                        let v = SoundAlikes.versions(of: s.text, around: spot, words: 5)
                        print("EVAL spot \(s.id) \(adv.map { String(format: "%+.2f", $0) } ?? "nil")  “\(v.heard)” → “\(spot.term)”")
                    }
                }
            }
            let checks = scoredLabelled.reduce(0) { $0 + $1.checks.count }
            let before = scoredLabelled.reduce(0) { n, s in n + s.checks.filter { passes(output(s, margin: nil), $0) }.count }
            let beforeOthers = scoredOthers.map { output($0, margin: nil) }
            print("EVAL before: \(before) of \(checks) checks")
            for m in Self.margins {
                let pass = scoredLabelled.reduce(0) { n, s in n + s.checks.filter { passes(output(s, margin: m), $0) }.count }
                let changed = zip(scoredOthers, beforeOthers).filter { output($0.0, margin: m) != $0.1 }.count
                // Wrong swaps: labelled checks that passed before and fail now.
                let broke = scoredLabelled.reduce(0) { n, s in
                    n + s.checks.filter { passes(output(s, margin: nil), $0) && !passes(output(s, margin: m), $0) }.count
                }
                print(String(format: "EVAL margin %+.1f: %d of %d checks (%d broken) | %d of %d other dictations changed",
                             m, pass, checks, broke, changed, scoredOthers.count))
            }
            let sorted = times.sorted()
            if !sorted.isEmpty {
                print(String(format: "EVAL load %.1fs | context check p50 %.2fs p90 %.2fs (%d spots)", loadSeconds,
                             sorted[sorted.count / 2], sorted[sorted.count * 9 / 10], sorted.count))
            }
            await runner.unload()
        }
    }
}
