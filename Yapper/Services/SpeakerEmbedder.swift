import Foundation
import FluidAudio

/// A voice as numbers: WeSpeaker, from FluidAudio's diarization models (13 MB, on the Neural
/// Engine). Two clips of the same person point the same way; `VoicePrint` compares them.
///
/// On the user's dictations it told a background show from the user's own quiet speech far more
/// cleanly than FluidAudio's CAM++ model, which put one of the user's runs below the show.
/// Not Sendable (the diarizer isn't); `ParakeetTranscriber` owns it on its actor.
final class SpeakerEmbedder {
    static let model = "wespeaker_v2"
    /// WeSpeaker takes a fixed 10 s window; longer audio is judged on its first 10 s.
    static let window = 160_000

    private let diarizer: DiarizerManager
    private let maskFrames: Int

    private init(diarizer: DiarizerManager, maskFrames: Int) {
        self.diarizer = diarizer
        self.maskFrames = maskFrames
    }

    /// Downloads the models the first time.
    static func load() async throws -> SpeakerEmbedder {
        let diarizer = DiarizerManager()
        diarizer.initialize(models: try await DiarizerModels.downloadIfNeeded())
        let frames = diarizer.segmentationModel?.modelDescription
            .outputDescriptionsByName["segments"]?.multiArrayConstraint?.shape[1].intValue ?? 589
        return SpeakerEmbedder(diarizer: diarizer, maskFrames: frames)
    }

    /// The voice in 16 kHz mono samples. The window is zero-padded and the mask covers only the
    /// real audio, so a 3 s clip isn't judged as 3 s of voice and 7 s of silence.
    func embed(_ samples: [Float]) -> [Float]? {
        guard let extractor = diarizer.embeddingExtractor, !samples.isEmpty else { return nil }
        let clip = Array(samples.prefix(Self.window))
        let covered = min(maskFrames, Int((Double(clip.count) / Double(Self.window) * Double(maskFrames)).rounded(.up)))
        let mask = (0..<maskFrames).map { $0 < covered ? Float(1) : 0 }
        let padded = clip + [Float](repeating: 0, count: Self.window - clip.count)
        return try? extractor.getEmbeddings(audio: padded, masks: [mask]).first
    }
}
