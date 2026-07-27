import Foundation

/// Owns the active playback session: picks ElevenLabs vs the native fallback, streams the audio,
/// and exposes the live player (or NativeTTSSpeaker) for the mini player to drive.
@MainActor
final class TTSCoordinator: ObservableObject {

    enum Engine {
        case elevenLabs(SentenceStreamPlayer)
        case native(NativeTTSSpeaker)
    }

    @Published private(set) var active: Engine?

    /// Number of items waiting behind the currently-playing one (Conversation Mode queue).
    @Published private(set) var queueCount: Int = 0

    private struct QueueItem {
        let item: ReadingItem
        let voice: VoicePreset
        let onStarted: (URL?) -> Void
    }
    private var queue: [QueueItem] = []

    private let keychain: Keychain
    private let settings: SettingsStore

    init(keychain: Keychain, settings: SettingsStore) {
        self.keychain = keychain
        self.settings = settings
    }

    /// Pause / resume whichever engine is active. Called from a contextual hotkey tap.
    var isPlaying: Bool {
        switch active {
        case .elevenLabs(let s): s.state == .playing || s.state == .bufferingFirstAudio
        case .native(let n): n.state == .speaking
        case nil: false
        }
    }

    func pauseOrResume() {
        switch active {
        case .elevenLabs(let s):
            if s.state == .playing { s.pause() }
            else if s.state == .paused { s.resume() }
        case .native(let n):
            if n.state == .speaking { n.pause() }
            else if n.state == .paused { n.resume() }
        case nil: break
        }
    }

    func stop() {
        stopActiveOnly()
        clearQueue()
    }

    /// Stop the active engine without touching the queue (used by skip-to-next).
    private func stopActiveOnly() {
        switch active {
        case .elevenLabs(let s): s.stop()
        // Clear the native finish hook first so the resulting didCancel doesn't advance the queue.
        case .native(let n): n.onFinish = nil; n.stop()
        case nil: break
        }
        active = nil
    }

    // MARK: - Conversation Mode queue

    /// Append a response to the FIFO queue. Starts immediately only if nothing is playing;
    /// otherwise it plays after the current item finishes — so reads never overlap.
    func enqueue(_ item: ReadingItem, voice: VoicePreset, onStarted: @escaping (URL?) -> Void) {
        queue.append(QueueItem(item: item, voice: voice, onStarted: onStarted))
        queueCount = queue.count
        if active == nil { startNextFromQueue() }
    }

    /// Skip the current item and play the next queued one (or go idle if the queue is empty).
    func skipToNext() {
        stopActiveOnly()
        startNextFromQueue()
    }

    func clearQueue() {
        queue.removeAll()
        queueCount = 0
    }

    private func startNextFromQueue() {
        guard active == nil else { return }
        guard !queue.isEmpty else { queueCount = 0; return }
        let next = queue.removeFirst()
        queueCount = queue.count
        let url = speakInternal(next.item.cleanedText, voice: next.voice, advanceOnFinish: true)
        next.onStarted(url)
    }

    /// Preview a voice with a fixed sample line. Used by the Voices tab preview button.
    func preview(_ voice: VoicePreset) {
        let sample = "Hi, I'm \(voice.displayName). This is Yapper reading aloud."
        speak(sample, voice: voice)
    }

    /// Start reading `text` with the user's active voice. Streams via ElevenLabs if a key + voice
    /// are configured; otherwise falls back to the native synthesizer.
    /// Returns the cache file URL when synthesizing via ElevenLabs (so History can reference it for
    /// replay), or nil for the native path.
    /// Manual read (Read Latest / Selection / preview). Supersedes any conversation queue.
    @discardableResult
    func speak(_ text: String, voice: VoicePreset) -> URL? {
        stop()   // stops the active engine AND clears the conversation queue
        return speakInternal(text, voice: voice, advanceOnFinish: false)
    }

    @discardableResult
    private func speakInternal(_ text: String, voice: VoicePreset, advanceOnFinish: Bool) -> URL? {
        let key = keychain.get(.elevenLabsKey) ?? ""
        let canUseElevenLabs = voice.provider == .elevenLabs && !key.isEmpty

        Log.tts.info("speak decision: voice=\(voice.displayName, privacy: .public) provider=\(voice.provider.rawValue, privacy: .public) elVoiceID=\(voice.providerVoiceID, privacy: .public) keyPresent=\(!key.isEmpty, privacy: .public) → engine=\(canUseElevenLabs ? "ElevenLabs" : "native", privacy: .public)")

        if canUseElevenLabs {
            return startElevenLabs(text: text, voice: voice, apiKey: key, advanceOnFinish: advanceOnFinish)
        } else {
            startNative(text: text, voice: voice, advanceOnFinish: advanceOnFinish)
            return nil
        }
    }

    /// Replay an already-synthesized MP3 straight from the History/TTS cache — no network call.
    /// `text` is only used to populate the transcript; playback comes entirely from the file.
    func replay(fileURL: URL, text: String = "") {
        stop()
        let player = SentenceStreamPlayer(existingFile: fileURL, text: text)
        player.setRate(Float(settings.playbackRate))
        player.onFinish = { [weak self] in self?.active = nil }
        active = .elevenLabs(player)
        player.start()
    }

    @discardableResult
    private func startElevenLabs(text: String, voice: VoicePreset, apiKey: String, advanceOnFinish: Bool) -> URL {
        let cacheURL = Self.cacheDir().appendingPathComponent("\(UUID().uuidString).mp3")

        // Soft character-limit check: log if we're over the model's per-request ceiling.
        if let model = ElevenLabsModel(rawValue: settings.elevenLabsModelID),
           text.count > model.characterLimit {
            Log.tts.warning("Text is \(text.count) chars but \(model.displayName, privacy: .public) limit is \(model.characterLimit). Sending anyway — ElevenLabs may reject or truncate.")
        }

        let player = SentenceStreamPlayer(
            sentences: SentenceStreamPlayer.segments(from: text),
            voiceID: voice.providerVoiceID,
            modelID: settings.elevenLabsModelID,
            outputFormat: "mp3_44100_128",
            voiceSettings: .natural,
            apiKey: apiKey,
            cacheURL: cacheURL
        )
        player.setRate(Float(settings.playbackRate))   // start at the user's last-chosen speed
        player.onFinish = { [weak self] in
            self?.active = nil
            if advanceOnFinish { self?.startNextFromQueue() }
        }
        player.onFailure = { [weak self] in
            // Couldn't synthesize the first segment — fall back to the native voice.
            Log.tts.error("ElevenLabs synth failed; falling back to native voice.")
            self?.active = nil
            self?.startNative(text: text, voice: voice, advanceOnFinish: advanceOnFinish)
        }
        active = .elevenLabs(player)
        player.start()

        return cacheURL
    }

    private func startNative(text: String, voice: VoicePreset, advanceOnFinish: Bool) {
        let speaker = NativeTTSSpeaker()
        speaker.onFinish = { [weak self, weak speaker] in
            guard let self, let speaker else { return }
            // Ignore stale finishes (e.g. a speaker we already replaced).
            guard case .native(let current)? = self.active, current === speaker else { return }
            self.active = nil
            if advanceOnFinish { self.startNextFromQueue() }
        }
        active = .native(speaker)
        let voiceID: String? = voice.provider == .macOSNative ? voice.providerVoiceID : nil
        speaker.speak(text, voiceID: voiceID)
    }

    // MARK: - Paths

    static func cacheDir() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Yapper/audio-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
