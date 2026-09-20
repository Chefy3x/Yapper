import Testing
import Foundation

/// End-to-end turns through the coordinator with a fake mic, transcriber, and paste target.
/// Microphone permission is injected as granted so the runner's TCC state can't skip the flow.
@MainActor
struct VoiceInputCoordinatorTests {

    // MARK: Fakes

    final class FakeCapture: AudioCapturing {
        var onLevel: ((Float) -> Void)?
        var onInterrupted: (() -> Void)?
        private(set) var isRunning = false
        var samplesToReturn: [Float] = [Float](repeating: 0.1, count: 16_000)   // 1s
        private(set) var startCount = 0
        func start(deviceUID: String?) throws { isRunning = true; startCount += 1 }
        func stop() -> [Float] { isRunning = false; return samplesToReturn }
    }

    final class FakeTranscriber: Transcribing, @unchecked Sendable {
        let modelID: String
        var result = "hello world"
        private(set) var calls = 0
        private(set) var lastPrompt: String?
        init(modelID: String) { self.modelID = modelID }
        func prepare() async throws {}
        func transcribe(samples: [Float], prompt: String?) async throws -> String {
            calls += 1; lastPrompt = prompt; return result
        }
    }

    final class DeliveryLog: @unchecked Sendable { var delivered: [String] = [] }
    struct FakeDelivery: TextDelivering {
        let log: DeliveryLog
        func deliver(_ text: String) async throws { log.delivered.append(text) }
    }

    struct Rig {
        let coordinator: VoiceInputCoordinator
        let capture: FakeCapture
        let transcriber: FakeTranscriber
        let delivered: DeliveryLog
        let settings: SettingsStore
        let vocabulary: VocabularyStore
    }

    private func makeRig(handsFree: Bool = false, minUtterance: TimeInterval = 0.35) -> Rig {
        let settings = SettingsStore()
        settings.voiceInputEnabled = true
        settings.handsFreeEnabled = handsFree
        settings.inputDeviceUID = nil
        let capture = FakeCapture()
        let log = DeliveryLog()
        let transcriber = FakeTranscriber(modelID: settings.whisperModelID)
        let vocabulary = VocabularyStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("vocab-\(UUID().uuidString).json"))
        var vad = VoiceActivityDetector.Config()
        vad.silenceTimeout = 0.05
        vad.armTimeout = 0.3
        vad.baselineBuffers = 2
        vad.onsetBuffers = 2
        let coordinator = VoiceInputCoordinator(
            settings: settings, vocabulary: vocabulary, capture: capture, delivery: FakeDelivery(log: log),
            makeTranscriber: { _, onStatus in onStatus(.ready); return transcriber },
            vadConfig: vad, minUtterance: minUtterance,
            permissionStatus: { .granted })
        coordinator.downloadModel()   // installs the fake and flips status to .ready
        return Rig(coordinator: coordinator, capture: capture, transcriber: transcriber, delivered: log,
                   settings: settings, vocabulary: vocabulary)
    }

    private func settle(_ seconds: TimeInterval = 0.3) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func waitUntil(_ cond: @autoclosure () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    // MARK: Push-to-talk

    @Test func holdReleaseTranscribesAndPastes() async {
        let rig = makeRig()
        await settle()
        var bargedIn = false
        rig.coordinator.onBargeIn = { bargedIn = true }

        rig.coordinator.beginPushToTalk()
        #expect(rig.coordinator.state == .listening(.pushToTalk))
        #expect(rig.capture.isRunning)
        #expect(bargedIn)

        await settle(0.4)   // exceed minUtterance
        rig.coordinator.endPushToTalk()
        await waitUntil(rig.delivered.delivered.count == 1)
        #expect(rig.delivered.delivered == ["hello world"])
        #expect(rig.transcriber.calls == 1)
        await waitUntil(rig.coordinator.state == .idle)
        #expect(rig.coordinator.state == .idle)
    }

    @Test func accidentalShortHoldIsDropped() async {
        let rig = makeRig(minUtterance: 0.5)
        await settle()
        rig.capture.samplesToReturn = [Float](repeating: 0.1, count: 1_600)   // 0.1s
        rig.coordinator.beginPushToTalk()
        rig.coordinator.endPushToTalk()
        await settle(0.2)
        #expect(rig.transcriber.calls == 0)
        #expect(rig.delivered.delivered.isEmpty)
        #expect(rig.coordinator.state == .idle)
    }

    @Test func cancelDiscardsWithoutTranscribing() async {
        let rig = makeRig()
        await settle()
        rig.coordinator.beginPushToTalk()
        await settle(0.4)
        rig.coordinator.cancelPushToTalk()
        await settle(0.1)
        #expect(!rig.capture.isRunning)
        #expect(rig.transcriber.calls == 0)
        #expect(rig.coordinator.state == .idle)
    }

    @Test func emptyTranscriptIsNotDelivered() async {
        let rig = makeRig()
        await settle()
        rig.transcriber.result = ""
        var events: [String] = []
        rig.coordinator.onEvent = { events.append($0) }
        rig.coordinator.beginPushToTalk()
        await settle(0.4)
        rig.coordinator.endPushToTalk()
        await waitUntil(rig.coordinator.state == .idle && rig.transcriber.calls == 1)
        #expect(rig.delivered.delivered.isEmpty)
        #expect(events.contains("Didn't catch that"))
    }

    @Test func disabledVoiceInIgnoresTheHold() async {
        let rig = makeRig()
        await settle()
        rig.settings.voiceInputEnabled = false
        await settle(0.1)
        rig.coordinator.beginPushToTalk()
        #expect(rig.coordinator.state == .idle)
        #expect(rig.capture.startCount == 0)
    }

    @Test func deniedMicrophoneRefusesToListenAndSaysWhy() async {
        let settings = SettingsStore()
        settings.voiceInputEnabled = true
        let capture = FakeCapture()
        let log = DeliveryLog()
        let vocabulary = VocabularyStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("vocab-\(UUID().uuidString).json"))
        let coordinator = VoiceInputCoordinator(
            settings: settings, vocabulary: vocabulary, capture: capture, delivery: FakeDelivery(log: log),
            makeTranscriber: { _, onStatus in onStatus(.ready); return FakeTranscriber(modelID: "m") },
            permissionStatus: { .denied })
        coordinator.downloadModel()
        await settle()
        var events: [String] = []
        coordinator.onEvent = { events.append($0) }
        coordinator.beginPushToTalk()
        #expect(coordinator.state == .idle)
        #expect(capture.startCount == 0)
        #expect(events.last?.contains("Microphone denied") == true)
    }

    @Test func vocabularyBiasesThePromptAndFixesTheTranscript() async {
        let rig = makeRig()
        await settle()
        rig.vocabulary.addTerm("Yapper")
        rig.vocabulary.addReplacement(heard: "yap her", typed: "Yapper")
        rig.transcriber.result = "open yap her now"
        rig.coordinator.beginPushToTalk()
        await settle(0.4)
        rig.coordinator.endPushToTalk()
        await waitUntil(rig.delivered.delivered.count == 1)
        #expect(rig.delivered.delivered == ["open Yapper now"])
        #expect(rig.transcriber.lastPrompt == "Yapper.")
        #expect(rig.vocabulary.lastTranscript?.original == "open yap her now")
        #expect(rig.vocabulary.lastTranscript?.delivered == "open Yapper now")
    }

    // MARK: Hands-free

    @Test func handsFreeListensUntilSilenceThenPastes() async {
        let rig = makeRig(handsFree: true)
        await settle()
        rig.coordinator.armHandsFree()
        #expect(rig.coordinator.state == .listening(.handsFree))

        // Baseline, then speech, then silence past the (tiny) timeout.
        for _ in 0..<2 { rig.capture.onLevel?(0.002) }
        for _ in 0..<3 { rig.capture.onLevel?(0.1) }
        await settle(0.4)   // keep the hold longer than minUtterance
        rig.capture.onLevel?(0.1)
        await settle(0.1)
        rig.capture.onLevel?(0.002)   // silence, 0.1s > 0.05s timeout → turn ends

        await waitUntil(rig.delivered.delivered.count == 1)
        #expect(rig.delivered.delivered == ["hello world"])
    }

    @Test func handsFreeClosesQuietlyWhenNobodySpeaks() async {
        let rig = makeRig(handsFree: true)
        await settle()
        rig.coordinator.armHandsFree()
        await settle(0.35)                // past armTimeout
        rig.capture.onLevel?(0.002)       // the next buffer notices the timeout
        await waitUntil(rig.coordinator.state == .idle)
        #expect(rig.coordinator.state == .idle)
        #expect(rig.transcriber.calls == 0)
        #expect(rig.delivered.delivered.isEmpty)
    }

    @Test func handsFreeOffMeansArmIsANoOp() async {
        let rig = makeRig(handsFree: false)
        await settle()
        rig.coordinator.armHandsFree()
        #expect(rig.coordinator.state == .idle)
        #expect(rig.capture.startCount == 0)
    }

    @Test func holdOverridesAnArmedHandsFreeMic() async {
        let rig = makeRig(handsFree: true)
        await settle()
        rig.coordinator.armHandsFree()
        rig.coordinator.beginPushToTalk()
        #expect(rig.coordinator.state == .listening(.pushToTalk))
        #expect(rig.capture.startCount == 2)
        rig.coordinator.cancelPushToTalk()
    }

    @Test func disarmClosesTheMicWithoutTranscribing() async {
        let rig = makeRig(handsFree: true)
        await settle()
        rig.coordinator.armHandsFree()
        rig.coordinator.disarmHandsFree()
        #expect(rig.coordinator.state == .idle)
        #expect(!rig.capture.isRunning)
        #expect(rig.transcriber.calls == 0)
    }
}
