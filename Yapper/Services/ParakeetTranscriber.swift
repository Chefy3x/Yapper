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

    /// Idle longer than this and the Neural Engine has let the model go cold: a day of the
    /// user's dictations took 0.11 s to decode within 30 s of the last one, 0.31–0.41 s after.
    static let coldAfter: TimeInterval = 20
    private let onStatus: @Sendable (WhisperModelStatus) -> Void

    init(model: WhisperModel, onStatus: @escaping @Sendable (WhisperModelStatus) -> Void) {
        self.model = model
        self.onStatus = onStatus
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
        // Times first ("at four thirty" → 4:30), which the general conversion gets wrong; then
        // numbers to digits, held back to the ones people write as digits.
        let spoken = SpokenTimes.normalizeSpoken(result.text)
        let text = NumberStyle.restrain(spoken: spoken, written: TextNormalizer.shared.normalizeSentence(spoken))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let seconds = Double(samples.count) / AudioCapture.targetSampleRate
        Log.voice.notice("Parakeet transcribed \(String(format: "%.1f", seconds), privacy: .public)s of audio in \(String(format: "%.2f", Date().timeIntervalSince(started)), privacy: .public)s → \(text.count, privacy: .public) chars")
        return text
    }
}
