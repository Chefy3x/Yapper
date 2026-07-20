import Testing
import ApplicationServices
import Foundation

// Drives the completion-detection state machine directly with synthetic probes — no timer,
// no Accessibility. This is the logic that decides whether a response gets spoken once,
// twice, or never, so every rule gets a case.
@MainActor
struct ConversationWatcherTests {

    private let app = ConversationWatcher.RunningApp(pid: 4242, bundleID: "test.bundle", name: "TestApp")

    private func makeWatcher() -> ConversationWatcher {
        ConversationWatcher(settings: SettingsStore(), stabilityWindow: 0.05)
    }

    private func probe(_ text: String,
                       stop: Bool = false,
                       aiOK: Bool = true,
                       complete: Bool = true) -> AccessibilityReader.ProbeResult {
        AccessibilityReader.ProbeResult(
            visibleText: text,
            hasCompletionControl: complete,
            hasStopControl: stop,
            copyButton: complete ? AXUIElementCreateSystemWide() : nil,
            aiSiteOK: aiOK
        )
    }

    /// Two evaluate passes separated by more than the stability window — the normal path to a fire.
    private func detect(_ watcher: ConversationWatcher, text: String) {
        watcher.evaluate(app: app, probe: probe(text))
        Thread.sleep(forTimeInterval: 0.08)
        watcher.evaluate(app: app, probe: probe(text))
    }

    // MARK: - Detection

    @Test func firesOnceAfterTextIsStable() {
        let watcher = makeWatcher()
        var fired: [ConversationWatcher.PendingResponse] = []
        watcher.onResponseCompleted = { fired.append($0) }

        watcher.evaluate(app: app, probe: probe("Hello world"))
        #expect(fired.isEmpty)   // first sighting only starts the stability clock

        Thread.sleep(forTimeInterval: 0.08)
        watcher.evaluate(app: app, probe: probe("Hello world"))
        #expect(fired.count == 1)
        #expect(fired.first?.sourceApp == "TestApp")
    }

    @Test func neverRefiresTheSameResponse() {
        let watcher = makeWatcher()
        var fired: [ConversationWatcher.PendingResponse] = []
        watcher.onResponseCompleted = { fired.append($0) }

        detect(watcher, text: "Same response")
        detect(watcher, text: "Same response")
        #expect(fired.count == 1)
    }

    @Test func streamingTextKeepsResettingTheClock() {
        let watcher = makeWatcher()
        var fired: [ConversationWatcher.PendingResponse] = []
        watcher.onResponseCompleted = { fired.append($0) }

        for i in 0..<5 {   // text grows every tick, like a streaming reply
            watcher.evaluate(app: app, probe: probe("Streaming token \(i)"))
            Thread.sleep(forTimeInterval: 0.08)
        }
        #expect(fired.isEmpty)
    }

    @Test func stopControlResetsTheCandidate() {
        let watcher = makeWatcher()
        var fired: [ConversationWatcher.PendingResponse] = []
        watcher.onResponseCompleted = { fired.append($0) }

        watcher.evaluate(app: app, probe: probe("Reply text"))
        Thread.sleep(forTimeInterval: 0.08)
        // Still streaming per the stop button — must NOT fire even though text was stable.
        watcher.evaluate(app: app, probe: probe("Reply text", stop: true))
        #expect(fired.isEmpty)

        // Clock restarts after the stop control disappears.
        watcher.evaluate(app: app, probe: probe("Reply text"))
        #expect(fired.isEmpty)
        Thread.sleep(forTimeInterval: 0.08)
        watcher.evaluate(app: app, probe: probe("Reply text"))
        #expect(fired.count == 1)
    }

    @Test func nonAISiteNeverFires() {
        let watcher = makeWatcher()
        var fired: [ConversationWatcher.PendingResponse] = []
        watcher.onResponseCompleted = { fired.append($0) }

        watcher.evaluate(app: app, probe: probe("Some page text", aiOK: false))
        Thread.sleep(forTimeInterval: 0.08)
        watcher.evaluate(app: app, probe: probe("Some page text", aiOK: false))
        #expect(fired.isEmpty)
    }

    @Test func missingCompletionControlNeverFires() {
        let watcher = makeWatcher()
        var fired: [ConversationWatcher.PendingResponse] = []
        watcher.onResponseCompleted = { fired.append($0) }

        watcher.evaluate(app: app, probe: probe("Reply", complete: false))
        Thread.sleep(forTimeInterval: 0.08)
        watcher.evaluate(app: app, probe: probe("Reply", complete: false))
        #expect(fired.isEmpty)
    }

    @Test func emptyTextNeverFires() {
        let watcher = makeWatcher()
        var fired: [ConversationWatcher.PendingResponse] = []
        watcher.onResponseCompleted = { fired.append($0) }

        detect(watcher, text: "   ")
        #expect(fired.isEmpty)
    }

    // MARK: - Extraction retry

    @Test func retryUnmarksAndRefiresUpToTheCap() {
        let settings = SettingsStore()
        settings.conversationAllowlist = []   // keep the timer's ticks inert
        let watcher = ConversationWatcher(settings: settings, stabilityWindow: 0.05)
        watcher.start()   // retry requires a running watcher
        defer { watcher.stop() }

        var fired: [ConversationWatcher.PendingResponse] = []
        watcher.onResponseCompleted = { fired.append($0) }

        detect(watcher, text: "Response A")
        #expect(fired.count == 1)

        // Attempts 1 and 2 un-mark the response so it re-detects and re-fires.
        watcher.retryFailedExtraction(fired[0])
        detect(watcher, text: "Response A")
        #expect(fired.count == 2)

        watcher.retryFailedExtraction(fired[1])
        detect(watcher, text: "Response A")
        #expect(fired.count == 3)

        // Attempt 3 hits maxExtractionAttempts — permanently give up on this response.
        watcher.retryFailedExtraction(fired[2])
        detect(watcher, text: "Response A")
        #expect(fired.count == 3)
    }

    @Test func retryIsIgnoredWhenWatcherIsStopped() {
        let watcher = makeWatcher()   // never started
        var fired: [ConversationWatcher.PendingResponse] = []
        watcher.onResponseCompleted = { fired.append($0) }

        detect(watcher, text: "Response B")
        #expect(fired.count == 1)

        watcher.retryFailedExtraction(fired[0])   // no-op: isRunning is false
        detect(watcher, text: "Response B")
        #expect(fired.count == 1)
    }
}
