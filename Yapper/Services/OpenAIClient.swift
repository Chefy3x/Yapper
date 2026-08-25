import Foundation

/// Thin client for OpenAI's speech endpoint.
///   POST /v1/audio/speech
///
/// Deliberately narrower than `ElevenLabsClient`: OpenAI has no request-stitching or
/// previous/next-text conditioning, so each segment is synthesized in isolation. In practice that
/// costs a little prosodic continuity across sentence seams and buys a much simpler client.
struct OpenAIClient {
    enum ClientError: Error, LocalizedError {
        case missingAPIKey
        case http(status: Int, body: String?)
        case transport(Error)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: "No OpenAI API key configured."
            case .http(let s, let b): "OpenAI HTTP \(s)\(b.map { ": \($0.prefix(200))" } ?? "")"
            case .transport(let e): e.localizedDescription
            }
        }
    }

    struct Request {
        let voice: String
        let text: String
        let modelID: String
        let responseFormat: String
        /// Free-text delivery direction. Honoured by `gpt-4o-mini-tts` and ignored by the older
        /// `tts-1` models, which is why it's never required.
        let instructions: String?

        init(voice: String,
             text: String,
             modelID: String = OpenAIModel.defaultModel.rawValue,
             responseFormat: String = "mp3",
             instructions: String? = OpenAIClient.defaultInstructions) {
            self.voice = voice
            self.text = text
            self.modelID = modelID
            self.responseFormat = responseFormat
            self.instructions = instructions
        }
    }

    /// Matches the tuning that ElevenLabs gets through `VoiceSettings.natural` — composed and
    /// lightly expressive rather than the flat default read.
    static let defaultInstructions =
        "Read this aloud naturally and unhurried, like a person reading something they find worth reading."

    private struct Body: Encodable {
        let model: String
        let input: String
        let voice: String
        let response_format: String
        let instructions: String?
    }

    /// Synthesize one segment. Returns the complete audio data.
    static func synthesize(_ req: Request, apiKey: String) async throws -> Data {
        guard !apiKey.isEmpty else { throw ClientError.missingAPIKey }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            Body(model: req.modelID,
                 input: req.text,
                 voice: req.voice,
                 response_format: req.responseFormat,
                 // Sent only where it means something; tts-1 rejects unknown fields less
                 // gracefully than it ignores them.
                 instructions: req.modelID.hasPrefix("gpt-4o") ? req.instructions : nil)
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClientError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else { throw ClientError.http(status: -1, body: nil) }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.http(status: http.statusCode,
                                   body: String(data: data.prefix(2048), encoding: .utf8))
        }
        return data
    }

    /// `GET /v1/models` is the cheapest authenticated call OpenAI exposes.
    static func validate(apiKey: String) async -> APIKeyCheck {
        await APIKeyCheck.probe(url: URL(string: "https://api.openai.com/v1/models")!, key: apiKey) {
            request, key in request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }
}

/// The speech models OpenAI currently offers, cheapest-and-fastest first.
enum OpenAIModel: String, CaseIterable, Identifiable {
    case gpt4oMiniTTS = "gpt-4o-mini-tts"
    case tts1         = "tts-1"
    case tts1HD       = "tts-1-hd"

    var id: String { rawValue }
    static let defaultModel: OpenAIModel = .gpt4oMiniTTS

    var displayName: String {
        switch self {
        case .gpt4oMiniTTS: "GPT-4o mini TTS"
        case .tts1:         "TTS-1"
        case .tts1HD:       "TTS-1 HD"
        }
    }

    var blurb: String {
        switch self {
        case .gpt4oMiniTTS: "Newest. Takes delivery direction, best quality for the price."
        case .tts1:         "Older and lower latency. Flatter read."
        case .tts1HD:       "Older, higher fidelity, slower and dearer."
        }
    }
}
