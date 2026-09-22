import Foundation

/// One segment of synthesized speech.
struct SpeechSegment {
    let data: Data
    /// Provider-side handle for stitching the next generation onto this one. Providers without
    /// that concept return nil and lose nothing but a little continuity across sentence seams.
    let requestID: String?
}

/// One provider's segment synthesis, seen from the streaming player.
///
/// The player stays deliberately ignorant of who is speaking: it schedules segments, tracks the
/// playhead and assembles the cache. Everything provider-shaped — auth, model ids, prosodic
/// conditioning, stitching — lives behind this single call.
protocol SpeechSynthesizing: Sendable {
    func synthesize(text: String,
                    previousText: String?,
                    nextText: String?,
                    previousRequestIDs: [String]) async throws -> SpeechSegment
}

/// ElevenLabs, with the full conditioning contract: neighbouring text for prosody, and request
/// stitching so consecutive segments sound like one continuous performance rather than a series
/// of separately-recorded sentences.
struct ElevenLabsSynthesizer: SpeechSynthesizing {
    let voiceID: String
    let modelID: String
    let outputFormat: String
    let voiceSettings: ElevenLabsClient.VoiceSettings
    let apiKey: String

    func synthesize(text: String, previousText: String?, nextText: String?,
                    previousRequestIDs: [String]) async throws -> SpeechSegment {
        let result = try await ElevenLabsClient.synthesize(
            ElevenLabsClient.Request(
                voiceID: voiceID,
                text: text,
                modelID: modelID,
                outputFormat: outputFormat,
                voiceSettings: voiceSettings,
                previousText: previousText,
                nextText: nextText,
                previousRequestIDs: previousRequestIDs
            ),
            apiKey: apiKey
        )
        return SpeechSegment(data: result.data, requestID: result.requestID)
    }
}

/// OpenAI. The API offers neither stitching nor neighbour conditioning, so those arguments are
/// accepted and dropped rather than faked into something that reads like continuity.
struct OpenAISynthesizer: SpeechSynthesizing {
    let voice: String
    let modelID: String
    let apiKey: String

    func synthesize(text: String, previousText: String?, nextText: String?,
                    previousRequestIDs: [String]) async throws -> SpeechSegment {
        let data = try await OpenAIClient.synthesize(
            OpenAIClient.Request(voice: voice, text: text, modelID: modelID),
            apiKey: apiKey
        )
        return SpeechSegment(data: data, requestID: nil)
    }
}
