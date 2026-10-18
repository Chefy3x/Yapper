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

    func transcribe(samples: [Float], prompt: String?) async throws -> String {
        try await prepare()
        guard let manager else { throw WhisperTranscriber.TranscriberError.notLoaded }
        let started = Date()
        // Same gate as Whisper: a recording with nobody talking types nothing.
        guard TranscriptFilter.hasSpeech(samples) else { return "" }
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
