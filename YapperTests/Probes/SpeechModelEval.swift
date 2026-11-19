import Testing
import Foundation
import SQLite3
import FluidAudio
import NaturalLanguage

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

    /// Ultra (25 languages) against v2 (English only) on Yapper's own saved dictations.
    /// YAPPER_ASR_EVAL_YAPPER=<Yapper's Application Support folder>, YAPPER_ASR_EVAL_N as above.
    /// The reference is the text Yapper typed, which Ultra wrote, so word errors lean Ultra's way;
    /// the number to watch is how many outputs aren't English.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAPPER_ASR_EVAL_YAPPER"] != nil))
    func englishOnlyOnSavedDictations() async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["YAPPER_ASR_EVAL_YAPPER"]!)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathComponent("dictations.json")))
        let rows = ((json as? [[String: Any]]) ?? []).compactMap { row -> (String, String)? in
            guard let file = row["audioFileName"] as? String, let text = row["text"] as? String, !text.isEmpty else { return nil }
            return (file, text)
        }
        let picked = rows.count <= Self.sample ? rows
            : (0..<Self.sample).map { rows[Int(Double($0) * Double(rows.count) / Double(Self.sample))] }
        let converter = AudioConverter()
        let clips = picked.compactMap { file, text -> Clip? in
            let path = base.appendingPathComponent("Dictations").appendingPathComponent(file).path
            guard let audio = try? converter.resampleAudioFile(path: path), audio.count > 16_000 else { return nil }
            return Clip(audio: audio, seconds: Double(audio.count) / 16_000, reference: text)
        }
        print(String(format: "EVAL %d dictations, %.1f minutes", clips.count, clips.reduce(0) { $0 + $1.seconds } / 60))

        func foreign(_ text: String) -> Bool {
            if text.unicodeScalars.contains(where: { $0.value > 0x7F && CharacterSet.letters.contains($0) }) { return true }
            guard Self.words(text).count >= 4 else { return false }
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            return recognizer.dominantLanguage != .english
        }
        var results: [Score] = []
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
        for r in results {
            print(r.report() + "  | not English \(r.outputs.filter(foreign).count)")
        }
        var shown = 0
        for i in clips.indices where shown < 10 && foreign(results[0].outputs[i]) {
            print("EVAL  ultra: \(results[0].outputs[i])\nEVAL  v2:    \(results[1].outputs[i])")
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
            print("PROBE \(raw)\nPROBE   → \(SpokenNumbers.write(spoken))")
        }
    }

    /// YAPPER_RAW_FILES=<comma-separated wav paths>: Parakeet's raw text, then each pipeline step.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAPPER_RAW_FILES"] != nil))
    func rawParakeet() async throws {
        let paths = ProcessInfo.processInfo.environment["YAPPER_RAW_FILES"]!.split(separator: ",").map(String.init)
        let version = ParakeetTranscriber.version
        let models = try await AsrModels.downloadAndLoad(version: version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        for path in paths {
            let audio = try AudioConverter().resampleAudioFile(path: path)
            var state = TdtDecoderState.make(decoderLayers: version.decoderLayers)
            let raw = try await manager.transcribe(audio, decoderState: &state).text
            let spoken = SpokenTimes.normalizeSpoken(raw)
            let itn = TextNormalizer.shared.normalizeSentence(spoken)
            print("PROBE file: \(path)\nPROBE raw:  \(raw)\nPROBE itn:  \(itn)\nPROBE new:  \(SpokenNumbers.write(spoken))")
        }
    }

    /// Late-night dictations the user corrected by ear: does levelling the audio, or handing
    /// Parakeet's unsure clips to Whisper, fix mumbled words? YAPPER_LATE_EVAL=<labels.json>
    /// ([{file, text, status}], status "ok" = checked), YAPPER_LATE_AUDIO=<Yapper's Dictations folder>.
    /// The labels are the user's speech: keep them out of the repo.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAPPER_LATE_EVAL"] != nil))
    func lateNightMumbles() async throws {
        let env = ProcessInfo.processInfo.environment
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: env["YAPPER_LATE_EVAL"]!))) as? [[String: Any]] ?? []
        let dir = URL(fileURLWithPath: env["YAPPER_LATE_AUDIO"]!)
        let converter = AudioConverter()
        let clips = rows.compactMap { row -> Clip? in
            guard row["status"] as? String == "ok", let file = row["file"] as? String, let text = row["text"] as? String,
                  let audio = try? converter.resampleAudioFile(path: dir.appendingPathComponent(file).path) else { return nil }
            return Clip(audio: audio, seconds: Double(audio.count) / 16_000, reference: text)
        }
        print(String(format: "EVAL %d checked late-night dictations, %.1f minutes", clips.count, clips.reduce(0) { $0 + $1.seconds } / 60))

        // Parakeet v2 as Yapper runs it, keeping each clip's lowest word confidence.
        let models = try await AsrModels.downloadAndLoad(version: .v2)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        var lowest: [Float] = []
        func parakeet(_ audio: [Float], keep: Bool = false) async throws -> String {
            var state = TdtDecoderState.make(decoderLayers: AsrModelVersion.v2.decoderLayers)
            let result = try await manager.transcribe(audio, decoderState: &state)
            if keep { lowest.append((result.tokenTimings ?? []).map(\.confidence).min() ?? 1) }
            return result.text
        }
        _ = try await parakeet(clips[0].audio)
        let plain = try await score("Parakeet v2", clips) { try await parakeet($0.audio, keep: true) }
        let levelled = try await score("Parakeet v2 levelled", clips) { try await parakeet(AudioConditioner.condition($0.audio).samples) }

        let whisper = WhisperTranscriber(model: .named(WhisperModel.formerDefaultID)) { _ in }
        try await whisper.prepare()
        _ = try await whisper.transcribe(samples: clips[0].audio, prompt: nil)
        let turbo = try await score("Whisper L3 Turbo", clips) { try await whisper.transcribe(samples: $0.audio, prompt: nil) }
        for r in [plain, levelled, turbo] { print(r.report()) }

        // Whisper only where Parakeet was unsure, at a few confidence lines; then the best either could do.
        let refs = clips.map { Self.words($0.reference) }
        let total = refs.reduce(0) { $0 + $1.count }
        func errors(_ outputs: [String], _ i: Int) -> Int { Self.edits(refs[i], Self.words(outputs[i])) }
        for line: Float in [0.3, 0.5, 0.7, 0.8, 0.9] {
            let switched = clips.indices.filter { lowest[$0] < line }
            let e = clips.indices.reduce(0) { $0 + errors(lowest[$1] < line ? turbo.outputs : plain.outputs, $1) }
            print(String(format: "EVAL Whisper below %.1f       word errors %5.1f%%  | %d of %d clips re-run", line, 100 * Double(e) / Double(total), switched.count, clips.count))
        }
        let best = clips.indices.reduce(0) { $0 + min(errors(plain.outputs, $1), errors(turbo.outputs, $1), errors(levelled.outputs, $1)) }
        print(String(format: "EVAL best of the three per clip word errors %5.1f%%", 100 * Double(best) / Double(total)))

        for i in clips.indices where errors(plain.outputs, i) > 0 {
            print(String(format: "EVAL [%d] lowest %.2f  errors parakeet %d levelled %d whisper %d", i, lowest[i],
                         errors(plain.outputs, i), errors(levelled.outputs, i), errors(turbo.outputs, i)))
            print("EVAL   said:     \(clips[i].reference)\nEVAL   parakeet: \(plain.outputs[i])\nEVAL   levelled: \(levelled.outputs[i])\nEVAL   whisper:  \(turbo.outputs[i])")
        }
    }

    /// Side by side for the user to judge: what Parakeet v2 heard on each saved dictation, next to
    /// Whisper Large v3 Turbo given the same vocabulary prompt Yapper gives it. No answer key; the
    /// user reads the differences. YAPPER_ASR_SIDE=<Yapper's Application Support folder>,
    /// YAPPER_ASR_SIDE_OUT=<json to write>, YAPPER_ASR_EVAL_N as above.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAPPER_ASR_SIDE"] != nil))
    func sideBySideOnSavedDictations() async throws {
        let env = ProcessInfo.processInfo.environment
        let base = URL(fileURLWithPath: env["YAPPER_ASR_SIDE"]!)
        let out = URL(fileURLWithPath: env["YAPPER_ASR_SIDE_OUT"] ?? NSTemporaryDirectory() + "asr-side.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathComponent("dictations.json")))
        let rows = ((json as? [[String: Any]]) ?? []).filter {
            ($0["audioFileName"] as? String) != nil && !(($0["heard"] as? String) ?? "").isEmpty
        }
        let picked = rows.count <= Self.sample ? rows
            : (0..<Self.sample).map { rows[Int(Double($0) * Double(rows.count) / Double(Self.sample))] }
        let vocab = (try? JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathComponent("vocabulary.json")))) as? [String: Any]
        let prompt = TranscriptCorrector.prompt(terms: (vocab?["terms"] as? [String]) ?? [])
        let converter = AudioConverter()
        let whisper = WhisperTranscriber(model: .named(WhisperModel.formerDefaultID)) { _ in }
        try await whisper.prepare()
        var results: [[String: Any]] = []
        var warmed = false
        for row in picked {
            let file = row["audioFileName"] as! String
            let path = base.appendingPathComponent("Dictations").appendingPathComponent(file).path
            guard let audio = try? converter.resampleAudioFile(path: path), audio.count > 16_000 else { continue }
            if !warmed { _ = try await whisper.transcribe(samples: audio, prompt: prompt); warmed = true }
            let started = Date()
            let heard = try await whisper.transcribe(samples: audio, prompt: prompt)
            results.append([
                "id": row["id"] ?? file, "at": row["at"] ?? "", "app": row["appName"] ?? "",
                "seconds": Double(audio.count) / 16_000, "whisperCompute": Date().timeIntervalSince(started),
                "parakeet": row["heard"] ?? "", "whisper": heard, "pasted": row["text"] ?? "",
            ])
        }
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted]).write(to: out)
        print("EVAL side by side: \(results.count) dictations written to \(out.path)")
    }
}
