import Testing
import Foundation

/// Opt-in: runs the downloaded formatting model on sample dictations and prints what came out,
/// the guard's verdict, and the time. Set YAPPER_FORMAT_PROBE=1 (needs the model downloaded).
struct FormatterProbe {
    static let enabled = ProcessInfo.processInfo.environment["YAPPER_FORMAT_PROBE"] != nil

    static let cases: [(String, FormatMode)] = [
        ("Let's do the review at 2, no wait, 3 o'clock on Thursday.", .chat),
        ("I need you to do a few things. First, update the readme. Second, fix the failing test. And third, push the branch.", .chat),
        ("Tell Jordan I'll be late, I mean, tell Priya I'll be late.", .chat),
        ("Can you look at the login bug and, actually, make that the signup bug.", .chat),
        ("For the grocery run I need three things, first eggs, second oat milk, and third coffee beans.", .document),
        ("There are three steps. First, pull main. Second, run the tests. Third, open a PR.", .terminal),
        ("I mean it, this is the best version so far.", .chat),
        ("Okay so the plan is, number one, we ship the fix tonight, number two, we write the post tomorrow, and number three, we take Friday off.", .email),
        ("Book the flight for the 12th, no wait, the 14th, and get a window seat.", .chat),
        ("So first, we got the login screen. Second, we have the settings page. Third, we have the onboarding flow.", .chat),
        ("Number one, fix the login bug. Number two, ship the update. Number three, tell the team.", .chat),
        ("Okay so there's a few things I want to do today, first is the video edit, second is the thumbnail, and third is posting it.", .chat),
        ("My number one priority this week is the launch video.", .chat),
    ]

    @Test(.enabled(if: enabled && FormatterModel.isDownloaded)) func sampleDictations() async throws {
        let runner = LlamaRunner(modelURL: FormatterModel.fileURL)
        let loadStart = Date()
        try await runner.load()
        print("PROBE load \(String(format: "%.2f", Date().timeIntervalSince(loadStart)))s")
        for (text, mode) in Self.cases {
            let started = Date()
            let raw = try await runner.generate(prefix: FormatPrompt.prefix(mode: mode, cleanup: true),
                                                suffix: FormatPrompt.suffix(text: text), maxTokens: 200,
                                                deadline: Date().addingTimeInterval(10))
            let elapsed = Date().timeIntervalSince(started)
            let verdict = FormatGuard.check(input: text, output: FormatPrompt.clean(raw.text), mode: mode, cleanup: true)
            print("PROBE [\(mode.rawValue)] \(String(format: "%.2f", elapsed))s prompt=\(raw.promptTokens) (\(String(format: "%.2f", raw.promptSeconds))s) gen=\(raw.generatedTokens) cue=\(FormatCues.needsFormatting(text, cleanup: true))")
            print("PROBE   in : \(text)")
            print("PROBE   out: \(FormatPrompt.clean(raw.text).replacingOccurrences(of: "\n", with: " ⏎ "))")
            print("PROBE   → \(verdict)")
        }
    }
}

/// Opt-in: the same formatting requests through several model files, side by side.
/// YAPPER_FORMAT_MODELS=<comma-separated .gguf paths>. Runs the probe's sample dictations plus
/// every kept dictation of the user's that would reach the model (a self-correction), through
/// the real guard and time budget.
@MainActor
struct FormatterModelComparison {
    nonisolated static let models = (ProcessInfo.processInfo.environment["YAPPER_FORMAT_MODELS"] ?? "")
        .split(separator: ",").map { URL(fileURLWithPath: String($0)) }

    struct Record: Decodable { let id: String; let heard: String? }

    private func inputs() -> [(String, FormatMode)] {
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Yapper/dictations.json")
        let records = (try? JSONDecoder().decode([Record].self, from: Data(contentsOf: file))) ?? []
        var seen: Set<String> = []
        let own = records.compactMap { $0.heard.map { Disfluency.clean($0) } }
            .filter { FormatEngine.plan($0, cleanup: true) != nil && seen.insert($0).inserted }
        return FormatterProbe.cases + own.map { ($0, FormatMode.chat) }
    }

    @Test(.enabled(if: !models.isEmpty)) func sideBySide() async throws {
        let cases = inputs()
        print("FMT \(cases.count) requests (\(FormatterProbe.cases.count) samples + \(cases.count - FormatterProbe.cases.count) of yours)")
        var outputs: [[String]] = []
        for url in Self.models {
            let runner = LlamaRunner(modelURL: url)
            try await runner.load()
            var counts: [String: Int] = [:], times: [Double] = [], texts: [String] = []
            for (text, mode) in cases {
                let started = Date()
                let result = await FormatEngine.format(text, mode: mode, cleanup: true, runner: runner)
                times.append(Date().timeIntervalSince(started))
                let key: String = switch result.outcome {
                case .formatted: "formatted"
                case .unchanged: "unchanged"
                case .rejected: "rejected"
                case .timedOut: "timed out"
                case .failed: "failed"
                case .skipped: "skipped"
                }
                counts[key, default: 0] += 1
                texts.append(result.text)
            }
            outputs.append(texts)
            let sorted = times.sorted()
            print("FMT ===== \(url.lastPathComponent): \(counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")) | p50 \(String(format: "%.2f", sorted[sorted.count / 2]))s p90 \(String(format: "%.2f", sorted[sorted.count * 9 / 10]))s")
            await runner.unload()
        }
        for (i, (text, _)) in cases.enumerated() {
            print("FMT --- [\(i)] in: \(text.replacingOccurrences(of: "\n", with: " ⏎ "))")
            for (m, url) in Self.models.enumerated() {
                let out = outputs[m][i]
                print("FMT   \(url.lastPathComponent.prefix(22)): \(out == text ? "(unchanged)" : out.replacingOccurrences(of: "\n", with: " ⏎ "))")
            }
        }
    }
}
