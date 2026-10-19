import Testing
import AppKit
import SwiftUI

/// Opt-in: renders every Settings page to PNGs for review, with
/// invented sample data in temp stores (never the user's own dictionary or dictations).
/// Set YAPPER_SETTINGS_SHOTS=<output folder> (TEST_RUNNER_YAPPER_SETTINGS_SHOTS through xcodebuild).
@MainActor
struct SettingsScreenshots {
    nonisolated static let outDir = ProcessInfo.processInfo.environment["YAPPER_SETTINGS_SHOTS"]

    @Test(.enabled(if: outDir != nil)) func renderSettingsPages() async throws {
        let out = URL(fileURLWithPath: Self.outDir!, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let stores = Self.sampleStores()
        let state = AppState.shared
        let settings = state.settings
        settings.voiceInputEnabled = true
        settings.dictationRetention = .week
        settings.whisperModelID = WhisperModel.recommended.id
        state.whisperModelStatus = .ready
        state.hasMicrophonePermission = true

        let heights: [YSection: CGFloat] = [.general: 760, .hotkeys: 900, .voiceIn: 1260, .dictations: 1180,
                                            .dictionary: 1240, .snippets: 900, .models: 1120, .voices: 900,
                                            .providers: 1100, .conversation: 1180, .history: 900, .about: 700]
        for section in YSection.allCases {
            let image = try await render(SettingsView(stores: stores, initial: section)
                .environmentObject(state)
                .environmentObject(settings),
                size: NSSize(width: 1000, height: heights[section] ?? 900), dark: false)
            try image.write(to: out.appendingPathComponent("\(section.rawValue).png"))
        }
        // The pill on its own, larger, in each state.
        let pills = HStack(spacing: 28) {
            RecordingPill(phase: .listening(locked: false, handsFree: false), motion: PillMotion(fixed: 0.75))
            RecordingPill(phase: .listening(locked: true, handsFree: false), motion: PillMotion(fixed: 0.75))
            RecordingPill(phase: .transcribing, motion: PillMotion(working: true))
        }
        .padding(40)
        .background(Brand.canvas)
        let pillImage = try await render(pills, size: NSSize(width: 820, height: 120), dark: false)
        try pillImage.write(to: out.appendingPathComponent("hud-pills.png"))
        // The pill opening out of its dot, frame by frame.
        let opening = HStack(spacing: 18) {
            ForEach([0.1, 0.3, 0.5, 0.7, 1.0], id: \.self) { t in
                RecordingPill(phase: .listening(locked: false, handsFree: false), motion: PillMotion(fixed: 0.75))
                    .modifier(PillOpen(open: t))
            }
        }
        .padding(40)
        .background(Brand.canvas)
        let openingImage = try await render(opening, size: NSSize(width: 980, height: 120), dark: false)
        try openingImage.write(to: out.appendingPathComponent("hud-opening.png"))
    }

    /// The three sounds, as the app renders them, for comparing against the listening page.
    @Test(.enabled(if: outDir != nil)) func renderSounds() throws {
        let out = URL(fileURLWithPath: Self.outDir!, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (sound, name) in [(DictationSound.start, "start"), (.done, "done"), (.failed, "failed")] {
            try DictationSounds.wav(sound.render(), sampleRate: SoundSynth.sampleRate)
                .write(to: out.appendingPathComponent("sound-\(name).wav"))
        }
    }


    private func render<V: View>(_ view: V, size: NSSize, dark: Bool) async throws -> Data {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: 0), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(700))
        host.layoutSubtreeIfNeeded()
        host.display()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    // MARK: Invented sample data

    static func sampleStores() -> VoiceInStores {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("YapperShots-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dictations = DictationHistoryStore(directory: dir)
        let tone: [Float] = (0..<16_000).map { Float(sin(Double($0) / 9)) * 0.1 }
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let samples: [(Double, String, String, String, Dictation.Outcome, Double, Bool)] = [
            (4000, "Notes", "pick up oat milk eggs and coffee beans on the way home", "Pick up oat milk, eggs, and coffee beans on the way home.", .pasted, 4.1, false),
            (2900, "Mail", "hi jordan um just checking the the invoice went through thanks", "Hi Jordan, just checking the invoice went through. Thanks!", .pasted, 6.3, false),
            (1500, "Slack", "", "", .empty, 1.2, true),
            (1450, "Slack", "can we move standup to ten fifteen tomorrow", "Can we move standup to 10:15 tomorrow?", .copied, 3.4, true),
            (95, "Terminal", "git checkout dash b fix slash login redirect", "git checkout -b fix/login-redirect", .pasted, 3.0, true),
            (42, "Claude", "first update the read me second fix the failing test and third push the branch", "1. Update the README.\n2. Fix the failing test.\n3. Push the branch.", .pasted, 7.8, true),
            (18, "Claude", "make the onboarding copy shorter no wait make it friendlier", "Make the onboarding copy friendlier.", .pasted, 4.6, true),
            (3, "Claude", "uh can you check why the quill base sync is failing on the kestrel branch", "Can you check why the Quillbase sync is failing on the Kestrel branch?", .pasted, 5.2, true),
        ]
        for (minutes, app, heard, text, outcome, seconds, audio) in samples {
            dictations.record(Dictation(at: ago(minutes), appName: app, bundleID: nil, heard: heard, text: text,
                                        duration: seconds, outcome: outcome, modelID: "parakeet-ultra"),
                              samples: audio ? tone : nil)
        }

        let snippets = SnippetStore(url: dir.appendingPathComponent("snippets.json"))
        _ = try? snippets.add(trigger: "sign off", expansion: "Thanks,\nSam")
        _ = try? snippets.add(trigger: "standup template", expansion: "Yesterday:\n- \nToday:\n- \nBlockers:\n- ")
        _ = try? snippets.add(trigger: "my address", expansion: "1 Example Street, Springfield 12345")
        _ = try? snippets.add(trigger: "my calendar link", expansion: "https://cal.example.com/sam/30min")
        _ = snippets.expand("my calendar link")
        _ = snippets.expand("my calendar link")
        _ = snippets.expand("sign off")

        let vocab = VocabularyStore(url: dir.appendingPathComponent("vocabulary.json"))
        vocab.addTerm("Kestrel")
        vocab.addTerm("Parakeet")
        vocab.addReplacement(heard: "kestral", typed: "Kestrel")
        vocab.merge(terms: ["Quillbase", "Tallis"], rules: [Replacement(heard: "quill base", typed: "Quillbase")])
        vocab.applyLearned([LearnedWord(heard: "vercell", typed: "Vercel", makesRule: true),
                            LearnedWord(heard: "Mara", typed: "Maura", makesRule: false)])
        vocab.dismissLearned()
        vocab.record(original: "can you check why the quill base sync is failing on the kestrel branch",
                     delivered: "Can you check why the Quillbase sync is failing on the Kestrel branch?")
        return VoiceInStores(dictations: dictations, snippets: snippets, vocabulary: vocab)
    }
}
