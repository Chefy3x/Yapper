import Foundation

/// Thin client for ElevenLabs' streaming TTS endpoint.
///   POST /v1/text-to-speech/{voice_id}/stream
/// Returns MP3 frames as they're synthesised so we can start playback before the full clip arrives.
struct ElevenLabsClient {
    enum ClientError: Error, LocalizedError {
        case missingAPIKey
        case http(status: Int, body: String?)
        case transport(Error)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: "No ElevenLabs API key configured."
            case .http(let s, let b): "ElevenLabs HTTP \(s)\(b.map { ": \($0.prefix(200))" } ?? "")"
            case .transport(let e): e.localizedDescription
            }
        }
    }

    /// Prosody controls sent with every request. If omitted, ElevenLabs uses the voice's stored
    /// defaults — typically stability ~0.5, which reads flat/monotone. Lower stability widens the
    /// emotional range; a touch of style adds expressiveness; speaker boost keeps the voice's
    /// identity. These are the dials that stop the read from sounding robotic.
    struct VoiceSettings: Encodable {
        var stability: Double
        var similarityBoost: Double
        var style: Double
        var useSpeakerBoost: Bool

        enum CodingKeys: String, CodingKey {
            case stability
            case similarityBoost  = "similarity_boost"
            case style
            case useSpeakerBoost  = "use_speaker_boost"
        }

        /// Natural, lightly expressive reading voice — de-monotoned but still composed, matching
        /// Yapper's "quiet competence" tone. Stability well below the 0.5 default is the main lever.
        /// No model-side `speed`: the user auditioned sped-up variants and found them less human.
        static let natural = VoiceSettings(
            stability: 0.40,
            similarityBoost: 0.80,
            style: 0.30,
            useSpeakerBoost: true
        )
    }

    struct Request {
        let voiceID: String
        let text: String
        let modelID: String         // e.g. eleven_flash_v2_5
        let outputFormat: String    // e.g. mp3_44100_128
        let voiceSettings: VoiceSettings
        /// Prosodic conditioning: the adjacent chunks' text so the model carries intonation across
        /// segment seams instead of re-deriving prosody from scratch per sentence. Not voiced —
        /// they only shape how `text` is delivered, so time-to-first-audio is unaffected.
        let previousText: String?
        let nextText: String?
        /// Request stitching: ids of the segments already synthesized (oldest → newest). The API
        /// conditions this generation on that *audio* — much stronger continuity than text alone —
        /// and ignores `previousText` whenever ids are present.
        let previousRequestIDs: [String]

        init(voiceID: String,
             text: String,
             modelID: String = ElevenLabsModel.defaultModel.rawValue,
             outputFormat: String = "mp3_44100_128",
             voiceSettings: VoiceSettings = .natural,
             previousText: String? = nil,
             nextText: String? = nil,
             previousRequestIDs: [String] = []) {
            self.voiceID = voiceID
            self.text = text
            self.modelID = modelID
            self.outputFormat = outputFormat
            self.voiceSettings = voiceSettings
            self.previousText = previousText
            self.nextText = nextText
            self.previousRequestIDs = previousRequestIDs
        }
    }

    /// The JSON body for the TTS endpoint. Optional context fields are omitted when nil (Swift's
    /// synthesized `Encodable` uses `encodeIfPresent` for optionals), so the first/last segments
    /// simply don't carry a `previous_text` / `next_text`.
    private struct Body: Encodable {
        let text: String
        let model_id: String
        let voice_settings: VoiceSettings
        let previous_text: String?
        let next_text: String?
        let previous_request_ids: [String]?

        init(_ req: Request) {
            self.text = req.text
            self.model_id = req.modelID
            self.voice_settings = req.voiceSettings
            self.previous_text = req.previousText
            self.next_text = req.nextText
            // The API accepts at most 3 ids; keep the most recent ones.
            self.previous_request_ids = req.previousRequestIDs.isEmpty
                ? nil : Array(req.previousRequestIDs.suffix(3))
        }
    }

    struct SynthesisResult {
        let data: Data
        /// The `request-id` response header — pass it as `previousRequestIDs` on the next segment
        /// so consecutive generations are stitched into one continuous performance.
        let requestID: String?
    }

    /// Synthesize a single segment and return the complete MP3 data plus its request id.
    /// Used by the sentence-streaming player, where each segment is small enough to fetch in one go.
    static func synthesize(_ req: Request, apiKey: String) async throws -> SynthesisResult {
        guard !apiKey.isEmpty else { throw ClientError.missingAPIKey }

        var components = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(req.voiceID)/stream")!
        components.queryItems = [URLQueryItem(name: "output_format", value: req.outputFormat)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        request.httpBody = try JSONEncoder().encode(Body(req))

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClientError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else { throw ClientError.http(status: -1, body: nil) }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.http(status: http.statusCode, body: String(data: data.prefix(2048), encoding: .utf8))
        }
        return SynthesisResult(data: data, requestID: http.value(forHTTPHeaderField: "request-id"))
    }

    /// Checks a key against the cheapest authenticated endpoint ElevenLabs documents.
    ///
    /// Saving an unchecked key is how a single typo turns into a voice that silently stops working
    /// an hour later, with nothing on screen connecting the two.
    static func validate(apiKey: String) async -> APIKeyCheck {
        await APIKeyCheck.probe(url: URL(string: "https://api.elevenlabs.io/v1/user")!, key: apiKey) {
            request, key in request.setValue(key, forHTTPHeaderField: "xi-api-key")
        }
    }

    /// Streams MP3 bytes for the given request. The stream throws on transport or HTTP errors.
    /// The closure form lets us await chunks in an `for try await` loop.
    static func stream(_ req: Request, apiKey: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard !apiKey.isEmpty else { throw ClientError.missingAPIKey }

                    var components = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(req.voiceID)/stream")!
                    components.queryItems = [URLQueryItem(name: "output_format", value: req.outputFormat)]

                    var request = URLRequest(url: components.url!)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
                    request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

                    request.httpBody = try JSONEncoder().encode(Body(req))

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw ClientError.http(status: -1, body: nil)
                    }
                    if !(200..<300).contains(http.statusCode) {
                        // Body is small for errors; collect it for the message.
                        var collected = Data()
                        for try await byte in bytes {
                            collected.append(byte)
                            if collected.count > 2048 { break }
                        }
                        let body = String(data: collected, encoding: .utf8)
                        throw ClientError.http(status: http.statusCode, body: body)
                    }

                    // Coalesce raw bytes into ~4 KB chunks so the downstream player doesn't
                    // have to deal with byte-by-byte appends.
                    var buffer = Data()
                    buffer.reserveCapacity(4096)
                    for try await byte in bytes {
                        buffer.append(byte)
                        if buffer.count >= 4096 {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch let e as ClientError {
                    continuation.finish(throwing: e)
                } catch {
                    continuation.finish(throwing: ClientError.transport(error))
                }
            }
        }
    }
}
