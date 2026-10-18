import Foundation
import WhisperKit

/// A speech-to-text model Yapper knows how to offer: a WhisperKit CoreML variant, or Parakeet
/// through FluidAudio. Downloaded on first use; never bundled.
struct WhisperModel: Identifiable, Hashable, Sendable {
    enum Engine: Sendable { case whisper, parakeet }

    let id: String            // WhisperKit variant name in the argmaxinc/whisperkit-coreml repo, or "parakeet-ultra"
    let displayName: String
    let blurb: String
    let approxSize: String
    var engine: Engine = .whisper

    static let repo = "argmaxinc/whisperkit-coreml"

    static let parakeet = WhisperModel(
        id: "parakeet-ultra", displayName: "Parakeet (fastest)",
        blurb: "As accurate as Large v3 Turbo and about ten times faster. 25 languages, most of them European. NVIDIA Parakeet, CC-BY-4.0.",
        approxSize: "≈ 600 MB", engine: .parakeet)

    /// Parakeet runs on the Neural Engine, so it's offered on Apple Silicon only.
    static var catalog: [WhisperModel] {
        #if arch(arm64)
        return [parakeet] + whisperCatalog
        #else
        return whisperCatalog
        #endif
    }

    static let whisperCatalog: [WhisperModel] = [
        .init(id: "openai_whisper-tiny.en", displayName: "Tiny (English)",
              blurb: "Fastest, least accurate. Fine for short commands.", approxSize: "≈ 40 MB"),
        .init(id: "openai_whisper-base.en", displayName: "Base (English)",
              blurb: "Quick and decent. The Intel default.", approxSize: "≈ 80 MB"),
        .init(id: "openai_whisper-small.en", displayName: "Small (English)",
              blurb: "Good accuracy, still snappy.", approxSize: "≈ 250 MB"),
        .init(id: "openai_whisper-large-v3-v20240930_turbo", displayName: "Large v3 Turbo",
              blurb: "Most accurate, any language. Needs Apple Silicon to feel instant.", approxSize: "≈ 1.5 GB"),
    ]

    /// The universal binary runs its native slice, so compile-time arch is the runtime machine.
    static var recommended: WhisperModel {
        #if arch(arm64)
        return parakeet
        #else
        return whisperCatalog[1]
        #endif
    }

    /// The previous Apple Silicon default, Large v3 Turbo; a stored choice of it predates Parakeet.
    static let formerDefaultID = "openai_whisper-large-v3-v20240930_turbo"

    static func named(_ id: String) -> WhisperModel {
        catalog.first { $0.id == id } ?? recommended
    }

    // MARK: Paths

    static func downloadBase() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Yapper/WhisperKit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// WhisperKit lays downloads out as `<base>/models/<repo>/<variant>`.
    var folder: URL {
        Self.downloadBase()
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(Self.repo, isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    /// A finished download has the compiled CoreML bundles in place. A partial one may have the
    /// folder but not the models, so check for the decoder specifically.
    var isDownloaded: Bool {
        if engine == .parakeet { return ParakeetTranscriber.isDownloaded }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: folder.path) else { return false }
        return items.contains { $0.hasSuffix(".mlmodelc") && $0.lowercased().contains("decoder") }
    }
}

// MARK: - Files on disk (Settings → Models)

extension WhisperModel {
    /// The folder this model's files live in.
    var storageFolder: URL {
        engine == .parakeet ? ParakeetTranscriber.cacheFolder : folder
    }

    /// Bytes the model takes on disk. Walks the folder, so call it off the main thread.
    nonisolated static func bytesOnDisk(at folder: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    /// Removes the downloaded files. The model in use is never deleted from under the
    /// transcriber; Settings only offers this for the others.
    func deleteFiles() throws {
        let url = storageFolder
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

/// Where a model is on its way from "never downloaded" to "loaded on the Neural Engine".
enum WhisperModelStatus: Equatable, Sendable {
    case notDownloaded
    /// Files are on disk but nothing is loaded — Voice In is switched off.
    case downloaded
    case downloading(progress: Double)
    case loading
    case ready
    case failed(String)

    var isReady: Bool { self == .ready }
    var isBusy: Bool {
        switch self {
        case .downloading, .loading: true
        default: false
        }
    }
}

/// The speech-to-text contract the coordinator depends on. Tests inject a fake.
protocol Transcribing: AnyObject, Sendable {
    var modelID: String { get }
    func prepare() async throws
    /// `prompt` is prior-context text that biases decoding toward the user's vocabulary.
    func transcribe(samples: [Float], prompt: String?) async throws -> String
}

/// WhisperKit wrapper. Downloads with progress on first use, keeps the pipeline resident while
/// Voice In is enabled so the first hold doesn't pay cold-start latency, and hands back plain
/// text that has already been through `TranscriptFilter`.
actor WhisperTranscriber: Transcribing {
    let model: WhisperModel
    nonisolated var modelID: String { model.id }

    /// WhisperKit's pipeline isn't Sendable, and its decode is a nonisolated async call — so
    /// the actor can't hand the raw object across. The box is the region the compiler accepts;
    /// only this actor ever touches it, and only through `decode`.
    private final class PipeBox: @unchecked Sendable {
        let kit: WhisperKit
        init(_ kit: WhisperKit) { self.kit = kit }
    }
    private var pipe: PipeBox?
    private var loadTask: Task<Void, Error>?
    private let onStatus: @Sendable (WhisperModelStatus) -> Void

    enum TranscriberError: LocalizedError {
        case notLoaded
        var errorDescription: String? { "The speech model isn't loaded" }
    }

    init(model: WhisperModel, onStatus: @escaping @Sendable (WhisperModelStatus) -> Void) {
        self.model = model
        self.onStatus = onStatus
    }

    /// Download (if needed) and load. Idempotent: concurrent callers share one in-flight task.
    func prepare() async throws {
        if pipe != nil { return }
        if let existing = loadTask { try await existing.value; return }
        let task = Task { try await self.performLoad() }
        loadTask = task
        do { try await task.value } catch { loadTask = nil; throw error }
    }

    private func performLoad() async throws {
        let model = self.model
        var folder = model.folder
        if !model.isDownloaded {
            onStatus(.downloading(progress: 0))
            do {
                folder = try await WhisperKit.download(
                    variant: model.id,
                    downloadBase: WhisperModel.downloadBase(),
                    from: WhisperModel.repo,
                    progressCallback: { [onStatus] progress in
                        // Hold at <1.0 so the UI never flashes "done" before load actually runs.
                        onStatus(.downloading(progress: min(progress.fractionCompleted, 0.99)))
                    }
                )
            } catch {
                onStatus(.failed(Self.short(error)))
                throw error
            }
        }
        onStatus(.loading)
        do {
            let config = WhisperKitConfig(
                model: model.id,
                downloadBase: WhisperModel.downloadBase(),
                modelRepo: WhisperModel.repo,
                modelFolder: FileManager.default.fileExists(atPath: folder.path) ? folder.path : nil,
                prewarm: true,
                load: true,
                download: true
            )
            let kit = try await WhisperKit(config)
            pipe = PipeBox(kit)
            onStatus(.ready)
            Log.voice.info("Whisper model loaded: \(model.id, privacy: .public)")
        } catch {
            onStatus(.failed(Self.short(error)))
            throw error
        }
    }

    func transcribe(samples: [Float], prompt: String?) async throws -> String {
        try await prepare()
        guard let pipe else { throw TranscriberError.notLoaded }
        let started = Date()
        // Judged on the raw recording: after a boost, room noise would pass for speech.
        let hasSpeech = TranscriptFilter.hasSpeech(samples)
        let conditioned = hasSpeech ? AudioConditioner.condition(samples)
            : AudioConditioner.Result(samples: samples, removedSeconds: 0, gain: 1)
        let segments = try await Self.decode(pipe, samples: conditioned.samples, prompt: prompt)
        let audioSeconds = Double(conditioned.samples.count) / AudioCapture.targetSampleRate
        let text = TranscriptFilter.join(segments, audioHasSpeech: hasSpeech, audioSeconds: audioSeconds)
        // .notice so the timing persists in the unified log: lag is measured, not guessed.
        Log.voice.notice("Transcribed \(String(format: "%.1f", audioSeconds), privacy: .public)s of audio (cut \(String(format: "%.1f", conditioned.removedSeconds), privacy: .public)s, gain \(String(format: "%.1f", conditioned.gain), privacy: .public)x) in \(String(format: "%.2f", Date().timeIntervalSince(started)), privacy: .public)s → \(text.count, privacy: .public) chars, \(segments.count, privacy: .public) segments, speech=\(hasSpeech, privacy: .public)")
        return text
    }

    /// Off until a WhisperKit release decodes prompted audio correctly; re-run the probe to check.
    nonisolated static let promptsWork = false

    /// Raw segments for one decode, unfiltered and unconditioned. For diagnosing a transcript
    /// that came back empty; the app itself always goes through `transcribe`.
    func rawSegments(samples: [Float], prompt: String?) async throws -> [TranscriptSegment] {
        try await prepare()
        guard let pipe else { throw TranscriberError.notLoaded }
        return try await Self.decode(pipe, samples: samples, prompt: prompt)
    }

    /// Runs the CoreML decode and flattens the result to Sendable segments before anything
    /// crosses back into the actor.
    private nonisolated static func decode(_ box: PipeBox, samples: [Float], prompt: String?) async throws -> [TranscriptSegment] {
        // Timestamps stay on: they're what lets TranscriptFilter drop segments Whisper invents
        // past the end of the recording (it decodes a padded 30 s window).
        var options = DecodingOptions()
        // Whisper's prompt (text "said before" this audio) is meant to bias spelling toward the
        // user's vocabulary. With WhisperKit 0.18 and Large v3 Turbo, any prompt, even one word,
        // makes the decoder end at once and return nothing (see WhisperLongDictationProbe). So
        // the prompt is only sent when `promptsWork` says so, and vocabulary is applied after
        // decoding instead (`TranscriptCorrector.respell`).
        if Self.promptsWork, let prompt, !prompt.isEmpty, let tokenizer = box.kit.tokenizer {
            let tokens = tokenizer.encode(text: " " + prompt)
            if !tokens.isEmpty { options.promptTokens = tokens }
        }
        let results = try await box.kit.transcribe(audioArray: samples, decodeOptions: options)
        return results.flatMap { result in
            result.segments.map {
                TranscriptSegment(text: $0.text, avgLogprob: $0.avgLogprob,
                                  noSpeechProb: $0.noSpeechProb, compressionRatio: $0.compressionRatio,
                                  start: $0.start)
            }
        }
    }

    private static func short(_ error: Error) -> String {
        let raw = error.localizedDescription
        return raw.count > 90 ? String(raw.prefix(90)) + "…" : raw
    }
}
