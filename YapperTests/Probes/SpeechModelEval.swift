import Testing
import Foundation
import SQLite3
import FluidAudio

/// Opt-in: Whisper (Yapper's full pipeline) against Parakeet on the user's own recordings.
/// YAPPER_ASR_EVAL=<copy of Wispr Flow's flow.sqlite>, YAPPER_ASR_EVAL_N=<sample size>.
/// The reference for each recording is the text Wispr Flow produced and the user kept, so both
/// models are judged against the same thing. Prints totals and a few short examples only.
struct SpeechModelEval {
    static let path = ProcessInfo.processInfo.environment["YAPPER_ASR_EVAL"]
    static let sample = Int(ProcessInfo.processInfo.environment["YAPPER_ASR_EVAL_N"] ?? "") ?? 120

    struct Clip { let audio: [Float]; let seconds: Double; let reference: String }

    private func clips() throws -> [Clip] {
        guard let path = Self.path else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro&immutable=1", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
        else { return [] }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT audio, formattedText FROM History
        WHERE audio IS NOT NULL AND length(audio) > 2000 AND duration BETWEEN 2 AND 60 AND formattedText IS NOT NULL
        ORDER BY timestamp
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [(Data, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let bytes = Int(sqlite3_column_bytes(stmt, 0))
            let data = Data(bytes: sqlite3_column_blob(stmt, 0), count: bytes)
            rows.append((data, String(cString: sqlite3_column_text(stmt, 1))))
        }
        let picked = rows.count <= Self.sample ? rows
            : (0..<Self.sample).map { rows[Int(Double($0) * Double(rows.count) / Double(Self.sample))] }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("asr-eval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let converter = AudioConverter()
        return try picked.enumerated().compactMap { i, row in
            let file = dir.appendingPathComponent("\(i).wav")
            try row.0.write(to: file)
            guard let audio = try? converter.resampleAudioFile(path: file.path), audio.count > 16_000 else { return nil }
            return Clip(audio: audio, seconds: Double(audio.count) / 16_000, reference: row.1)
        }
    }

    // MARK: Scoring

    private static let fillers: Set<String> = ["um", "uh", "uhm", "umm", "er", "erm", "hmm", "mm", "ah"]
    private static let numbers = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                                  "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
                                  "eighteen", "nineteen", "twenty"]

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty && !fillers.contains($0) }
            .map { numbers.firstIndex(of: $0).map(String.init) ?? $0 }
    }

    static func edits(_ ref: [String], _ hyp: [String]) -> Int {
        guard !ref.isEmpty else { return hyp.count }
        guard !hyp.isEmpty else { return ref.count }
        var prev = Array(0...hyp.count)
        for i in 1...ref.count {
            var cur = [i] + Array(repeating: 0, count: hyp.count)
            for j in 1...hyp.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[hyp.count]
    }

    struct Score {
        var name: String
        var errors = 0
        var refWords = 0
        var compute: [Double] = []
        var audioSeconds = 0.0
        var outputs: [String] = []
        var emptyOutputs = 0
        func report() -> String {
            let sorted = compute.sorted()
            return String(format: "EVAL %-22@ word errors %5.1f%%  | time p50 %.2fs p90 %.2fs  | %.0fx real time | empty %d",
                          name, 100 * Double(errors) / Double(max(1, refWords)),
                          sorted[sorted.count / 2], sorted[sorted.count * 9 / 10],
                          audioSeconds / max(0.001, sorted.reduce(0, +)), emptyOutputs)
        }
    }

    private func score(_ name: String, _ clips: [Clip], _ run: (Clip) async throws -> String) async rethrows -> Score {
        var s = Score(name: name)
        for clip in clips {
            let started = Date()
            let text = try await run(clip)
            s.compute.append(Date().timeIntervalSince(started))
            s.audioSeconds += clip.seconds
            let ref = Self.words(clip.reference)
            s.errors += Self.edits(ref, Self.words(text))
            s.refWords += ref.count
            if text.trimmingCharacters(in: .whitespaces).isEmpty { s.emptyOutputs += 1 }
            s.outputs.append(text)
        }
        return s
    }

    @Test(.enabled(if: path != nil)) func whisperAgainstParakeet() async throws {
        let clips = try clips()
        let minutes = clips.reduce(0) { $0 + $1.seconds } / 60
        print(String(format: "EVAL %d recordings, %.1f minutes of audio", clips.count, minutes))

        let whisper = WhisperTranscriber(model: .named(WhisperModel.formerDefaultID)) { _ in }
        try await whisper.prepare()
        _ = try await whisper.transcribe(samples: clips[0].audio, prompt: nil)   // warm
        var results = [try await score("Whisper L3 Turbo", clips) { try await whisper.transcribe(samples: $0.audio, prompt: nil) }]

        for (name, version) in [("Parakeet Ultra", AsrModelVersion.ultra), ("Parakeet v2 (English)", .v2)] {
            let models = try await AsrModels.downloadAndLoad(version: version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            var warm = TdtDecoderState.make(decoderLayers: version.decoderLayers)
            _ = try await manager.transcribe(clips[0].audio, decoderState: &warm)
            results.append(try await score(name, clips) { clip in
                var state = TdtDecoderState.make(decoderLayers: version.decoderLayers)
                return try await manager.transcribe(clip.audio, decoderState: &state).text
            })
        }
        for r in results { print(r.report()) }

        // Where the models disagree most, shortest first, so the difference is readable.
        let diffs = clips.indices.map { i -> (Int, Int) in
            let w = Self.words(results[0].outputs[i]), p = Self.words(results[1].outputs[i])
            return (i, Self.edits(w, p))
        }.filter { $0.1 >= 2 && clips[$0.0].reference.count < 160 }.sorted { $0.1 > $1.1 }.prefix(6)
        for (i, _) in diffs {
            print("EVAL  ref:      \(clips[i].reference)")
            for r in results { print("EVAL  \(r.name.prefix(10)): \(r.outputs[i])") }
        }
    }

    /// The pipelines as Yapper would run them: speech model, then number conversion (Parakeet
    /// only), times and stumble rules. YAPPER_ASR_EVAL_FULL=1.
    @Test(.enabled(if: path != nil && ProcessInfo.processInfo.environment["YAPPER_ASR_EVAL_FULL"] != nil))
    func fullPipelines() async throws {
        let clips = try clips()
        print(String(format: "EVAL %d recordings, %.1f minutes", clips.count, clips.reduce(0) { $0 + $1.seconds } / 60))
        func rules(_ s: String) -> String { Disfluency.clean(SpokenTimes.normalize(s)) }

        let whisper = WhisperTranscriber(model: .named(WhisperModel.formerDefaultID)) { _ in }
        try await whisper.prepare()
        _ = try await whisper.transcribe(samples: clips[0].audio, prompt: nil)
        var results = [try await score("Whisper + rules", clips) { rules(try await whisper.transcribe(samples: $0.audio, prompt: nil)) }]

        let models = try await AsrModels.downloadAndLoad(version: .ultra)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        let itn = TextNormalizer.shared
        func parakeet(_ audio: [Float]) async throws -> String {
            var state = TdtDecoderState.make(decoderLayers: AsrModelVersion.ultra.decoderLayers)
            return try await manager.transcribe(audio, decoderState: &state).text
        }
        _ = try await parakeet(clips[0].audio)
        results.append(try await score("Parakeet raw", clips) { try await parakeet($0.audio) })
        results.append(try await score("Parakeet + numbers + rules", clips) { rules(itn.normalizeSentence(try await parakeet($0.audio))) })
        results.append(try await score("Parakeet levelled + all", clips) {
            rules(itn.normalizeSentence(try await parakeet(AudioConditioner.condition($0.audio).samples)))
        })
        for r in results { print(r.report()) }

        // What number conversion did, on the recordings where it changed something.
        var shown = 0
        for i in clips.indices where shown < 8 {
            let raw = results[1].outputs[i], converted = itn.normalizeSentence(raw)
            guard raw != converted, raw.count < 200 else { continue }
            print("EVAL  numbers: \(raw)\nEVAL        → \(converted)")
            shown += 1
        }
    }

    /// YAPPER_NUMBERS_PROBE=1: the real normaliser plus Yapper's restraint, on known sentences.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAPPER_NUMBERS_PROBE"] != nil))
    func numberStyle() {
        for raw in ["Just water one plant. Then the next plant.", "I painted two uh walls in the first room.",
                    "The train leaves at twenty one oh four.", "Do we sort them one by one?",
                    "we have twenty five users and it costs five dollars", "it went up five percent in two thousand twenty five",
                    "let's meet at four thirty tomorrow", "the second one with the blue paint looks better"] {
            let spoken = SpokenTimes.normalizeSpoken(raw)
            print("PROBE \(raw)\nPROBE   → \(NumberStyle.restrain(spoken: spoken, written: TextNormalizer.shared.normalizeSentence(spoken)))")
        }
    }
}
