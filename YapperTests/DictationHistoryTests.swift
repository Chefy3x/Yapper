import Testing
import Foundation

// Settings → Dictations: what's kept, for how long, and that recordings never outlive their
// window. Every store lives in a temp dir; the real Application Support data is never touched.
@MainActor
struct DictationHistoryTests {

    private func makeDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("YapperDictations-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func dictation(_ text: String, ageHours: Double = 0, heard: String? = nil,
                           app: String = "Notes", outcome: Dictation.Outcome = .pasted) -> Dictation {
        Dictation(at: Date().addingTimeInterval(-ageHours * 3600), appName: app, bundleID: "com.example.notes",
                  heard: heard ?? text, text: text, duration: 1.5, outcome: outcome, modelID: "parakeet-ultra")
    }

    private let tone: [Float] = (0..<8_000).map { Float(sin(Double($0) / 7)) * 0.2 }

    @Test func recordsNewestFirstAndSurvivesARelaunch() {
        let dir = makeDir()
        let store = DictationHistoryStore(directory: dir)
        store.record(dictation("first"))
        store.record(dictation("second", heard: "um second"))
        #expect(store.entries.map(\.text) == ["second", "first"])

        let reloaded = DictationHistoryStore(directory: dir)
        #expect(reloaded.entries.map(\.text) == ["second", "first"])
        #expect(reloaded.entries.first?.heard == "um second")
        #expect(reloaded.entries.first?.appName == "Notes")
        #expect(reloaded.entries.first?.wasCleaned == true)
    }

    @Test func keepsTheRecordingAndPlaysItBack() async {
        let store = DictationHistoryStore(directory: makeDir())
        let entry = store.record(dictation("with audio"), samples: tone)
        #expect(entry.audioFileName != nil)
        let loaded = await store.loadAudio(for: entry)
        #expect(loaded?.count == tone.count)
        #expect(store.audioURL(for: entry) != nil)
    }

    @Test func withoutSamplesNothingIsWritten() async {
        let store = DictationHistoryStore(directory: makeDir())
        let entry = store.record(dictation("text only"))
        #expect(entry.audioFileName == nil)
        #expect(await store.loadAudio(for: entry) == nil)
    }

    @Test func pruneDropsWhatsOlderThanTheWindowWithItsAudio() async {
        let store = DictationHistoryStore(directory: makeDir())
        let old = store.record(dictation("old", ageHours: 30), samples: tone)
        store.record(dictation("new", ageHours: 1))
        await store.flushAudio()
        let oldFile = store.audioDir.appendingPathComponent(old.audioFileName!)
        #expect(FileManager.default.fileExists(atPath: oldFile.path))

        store.prune(retention: .day)
        #expect(store.entries.map(\.text) == ["new"])
        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
    }

    @Test func recordingsGoAfterAWeekEvenWhenTheTextStays() async {
        let store = DictationHistoryStore(directory: makeDir())
        let entry = store.record(dictation("ten days ago", ageHours: 240), samples: tone)
        await store.flushAudio()
        store.prune(retention: .month)
        #expect(store.entries.count == 1)
        #expect(store.entries.first?.audioFileName == nil)
        #expect(!FileManager.default.fileExists(atPath: store.audioDir.appendingPathComponent(entry.audioFileName!).path))
    }

    @Test func foreverKeepsTextButStillCapsAudio() async {
        let store = DictationHistoryStore(directory: makeDir())
        store.record(dictation("last year", ageHours: 24 * 365), samples: tone)
        await store.flushAudio()
        store.prune(retention: .forever)
        #expect(store.entries.count == 1)
        #expect(store.entries.first?.audioFileName == nil)
    }

    @Test func removeAndClearDeleteRecordings() async {
        let store = DictationHistoryStore(directory: makeDir())
        let a = store.record(dictation("a"), samples: tone)
        store.record(dictation("b"), samples: tone)
        await store.flushAudio()
        store.remove(a.id)
        #expect(store.entries.map(\.text) == ["b"])
        #expect(!FileManager.default.fileExists(atPath: store.audioDir.appendingPathComponent(a.audioFileName!).path))
        store.clearAll()
        #expect(store.entries.isEmpty)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: store.audioDir.path)) ?? []
        #expect(left.filter { $0.hasSuffix(".wav") }.isEmpty)
    }

    @Test func orphanRecordingsAreSwept() async {
        let store = DictationHistoryStore(directory: makeDir())
        let stray = store.audioDir.appendingPathComponent("\(UUID().uuidString).wav")
        try? Data("RIFF".utf8).write(to: stray)
        let kept = store.record(dictation("kept"), samples: tone)
        await store.flushAudio()
        store.sweepOrphanAudio()
        #expect(!FileManager.default.fileExists(atPath: stray.path))
        #expect(FileManager.default.fileExists(atPath: store.audioDir.appendingPathComponent(kept.audioFileName!).path))
    }

    @Test func transcribeAgainReplacesTheTextOnly() {
        let store = DictationHistoryStore(directory: makeDir())
        let entry = store.record(dictation("", outcome: .empty))
        store.update(entry.id, heard: "second go", text: "Second go.", outcome: .retried, modelID: "openai_whisper-base.en")
        let updated = store.entries.first
        #expect(updated?.text == "Second go.")
        #expect(updated?.outcome == .retried)
        #expect(updated?.at == entry.at)
        #expect(updated?.appName == "Notes")
    }

    @Test func searchMatchesTextHeardAndApp() {
        let store = DictationHistoryStore(directory: makeDir())
        store.record(dictation("Ship the café menu", app: "Mail"))
        store.record(dictation("Book flights", heard: "book the flights uh", app: "Safari"))
        #expect(store.search("cafe").map(\.text) == ["Ship the café menu"])
        #expect(store.search("UH").map(\.text) == ["Book flights"])
        #expect(store.search("safari").count == 1)
        #expect(store.search("  ").count == 2)
    }

    @Test func totalWordsCountsOnlyWhatWasTyped() {
        let store = DictationHistoryStore(directory: makeDir())
        store.record(dictation("one two three"))
        store.record(dictation("four five", outcome: .copied))
        store.record(dictation("", outcome: .empty))
        #expect(store.totalWords == 5)
    }
}
