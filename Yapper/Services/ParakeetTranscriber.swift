import Foundation
import FluidAudio

/// NVIDIA's Parakeet TDT (CC-BY-4.0), as FluidAudio's Core ML build, on the Neural Engine.
///
/// On the user's own recordings it was as accurate as Whisper Large v3 Turbo and about ten times
/// faster (0.08 s against 0.79 s for a typical dictation), so it's the default on Apple Silicon.
/// Two differences from Whisper are handled here: it writes numbers as words ("twenty one oh
/// four"), which FluidAudio's inverse text normalisation turns back into digits, and it takes
/// no prompt, which costs nothing because Yapper applies vocabulary after decoding anyway.
actor ParakeetTranscriber: Transcribing {
    let model: WhisperModel
    nonisolated var modelID: String { model.id }
    static let version: AsrModelVersion = .ultra

    private var manager: AsrManager?
    private var loadTask: Task<Void, Error>?
    private var lastRun = Date()
    private var warming: Task<Void, Never>?
    /// Tells the user's voice from the room's (`BackgroundSpeechGate`). Loads after Parakeet and
    /// never holds it up; until it and the voice print are ready, nothing is dropped.
    private var speaker: SpeakerEmbedder?
    private var voicePrint: VoicePrint
    private let voicePrintStore: VoicePrintStore

    /// Idle longer than this and the Neural Engine has let the model go cold: a day of the
    /// user's dictations took 0.11 s to decode within 30 s of the last one, 0.31–0.41 s after.
    static let coldAfter: TimeInterval = 20
    private let onStatus: @Sendable (WhisperModelStatus) -> Void

    init(model: WhisperModel, voicePrintStore: VoicePrintStore = VoicePrintStore(),
         onStatus: @escaping @Sendable (WhisperModelStatus) -> Void) {
        self.model = model
        self.onStatus = onStatus
        self.voicePrintStore = voicePrintStore
        self.voicePrint = voicePrintStore.load(model: SpeakerEmbedder.model)
    }

    static var cacheFolder: URL { AsrModels.defaultCacheDirectory(for: version) }

    static var isDownloaded: Bool { AsrModels.modelsExist(at: cacheFolder, version: version) }

    func prepare() async throws {
        if manager != nil { return }
        if let existing = loadTask { try await existing.value; return }
        let task = Task { try await self.performLoad() }
        loadTask = task
        do { try await task.value } catch { loadTask = nil; throw error }
    }

    private func performLoad() async throws {
        let onStatus = self.onStatus
        do {
            if !Self.isDownloaded {
                onStatus(.downloading(progress: 0))
                try await AsrModels.download(version: Self.version) { progress in
                    onStatus(.downloading(progress: min(progress.fractionCompleted, 0.99)))
                }
            }
            onStatus(.loading)
            let models = try await AsrModels.load(from: Self.cacheFolder, version: Self.version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            // The first decode compiles the Neural Engine plan; pay for it now, not on the first hold.
            var state = TdtDecoderState.make(decoderLayers: Self.version.decoderLayers)
            _ = try? await manager.transcribe([Float](repeating: 0, count: 16_000), decoderState: &state)
            self.manager = manager
            onStatus(.ready)
            Log.voice.info("Parakeet model loaded: \(Self.version.decoderLayers, privacy: .public) decoder layers")
            Task { await self.loadSpeaker() }
        } catch {
            let raw = error.localizedDescription
            onStatus(.failed(raw.count > 90 ? String(raw.prefix(90)) + "…" : raw))
            throw error
        }
    }

    /// Loudest 20 ms frame above this: something reached the mic. A muted or disconnected
    /// input sits around 0.0001; a quiet room around 0.001–0.002; soft speech on a quiet mic
    /// starts near 0.005.
    static let signalFloor: Float = 0.003

    static func hasSignal(_ samples: [Float]) -> Bool {
        (TranscriptFilter.frameLevels(samples).max() ?? 0) > signalFloor
    }

    private func loadSpeaker() async {
        guard speaker == nil else { return }
        do {
            speaker = try await SpeakerEmbedder.load()
            Log.voice.info("Speaker model loaded; voice print from \(self.voicePrint.count, privacy: .public) dictations")
        } catch {
            // Dictation works as before; background talk just isn't filtered.
            Log.voice.error("Speaker model didn't load: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A throwaway decode of one second of silence while the user is still talking, so the real
    /// one runs warm. Only after an idle spell; back-to-back dictations are warm already.
    func warm() async {
        guard let manager, warming == nil, Date().timeIntervalSince(lastRun) > Self.coldAfter else { return }
        lastRun = Date()
        warming = Task {
            let started = Date()
            var state = TdtDecoderState.make(decoderLayers: Self.version.decoderLayers)
            _ = try? await manager.transcribe([Float](repeating: 0, count: 16_000), decoderState: &state)
            Log.voice.info("Parakeet warmed in \(String(format: "%.2f", Date().timeIntervalSince(started)), privacy: .public)s")
            self.warming = nil
        }
    }

    func transcribe(samples: [Float], prompt: String?) async throws -> String {
        try await prepare()
        guard let manager else { throw WhisperTranscriber.TranscriberError.notLoaded }
        // One decode at a time: a warm-up still running finishes first.
        await warming?.value
        defer { lastRun = Date() }
        let started = Date()
        // Only a recording with no signal at all is skipped. Whisper's speech gate isn't used:
        // Parakeet doesn't invent words from silence the way Whisper does, and on a quiet mic
        // that gate threw away short sentences ("I like number one.") that were plainly there.
        guard Self.hasSignal(samples) else { return "" }
        var state = TdtDecoderState.make(decoderLayers: Self.version.decoderLayers)
        let result = try await manager.transcribe(samples, decoderState: &state)
        let words = buildWordTimings(from: result.tokenTimings ?? [])
            .map { BackgroundSpeechGate.Word(text: $0.word, start: $0.startTime, end: $0.endTime) }
        let levels = BackgroundSpeechGate.levels(of: words, samples: samples)
        var raw = result.text
        if let speaker, voicePrint.isReady {
            let voice = voicePrint
            let gated = BackgroundSpeechGate.keptWords(words, levels: levels, samples: samples) {
                speaker.embed($0).flatMap(voice.similarity)
            }
            if gated.dropped > 0 {
                raw = BackgroundSpeechGate.text(gated.words)
                Log.voice.notice("Dropped \(gated.dropped, privacy: .public) of \(words.count, privacy: .public) words in a voice that isn't the user's")
            }
        }
        // After the text is back, so learning the voice never adds to the wait.
        Task { self.learnVoice(words: words, levels: levels, samples: samples) }
        // Times first ("at four thirty" → 4:30), which the general conversion gets wrong; then
        // numbers to digits, held back to the ones people write as digits.
        let spoken = SpokenTimes.normalizeSpoken(raw)
        let text = NumberStyle.restrain(spoken: spoken, written: TextNormalizer.shared.normalizeSentence(spoken))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let seconds = Double(samples.count) / AudioCapture.targetSampleRate
        Log.voice.notice("Parakeet transcribed \(String(format: "%.1f", seconds), privacy: .public)s of audio in \(String(format: "%.2f", Date().timeIntervalSince(started)), privacy: .public)s → \(text.count, privacy: .public) chars")
        return text
    }

    /// Adds this dictation's loud words, the user near the mic, to the voice print.
    private func learnVoice(words: [BackgroundSpeechGate.Word], levels: [Float], samples: [Float]) {
        guard let speaker else { return }
        let loud = BackgroundSpeechGate.loudWords(levels: levels).map { words[$0] }
        let audio = BackgroundSpeechGate.audio(of: loud, in: samples)
        guard Double(audio.count) / AudioCapture.targetSampleRate >= VoicePrint.minLearnSeconds,
              let embedding = speaker.embed(audio) else { return }
        voicePrint.learn(embedding)
        voicePrintStore.save(voicePrint)
    }
}
