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
