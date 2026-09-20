import Foundation
import Combine

/// Runs one voice turn end to end: open the mic, decide when the turn is over, transcribe on
/// this Mac, paste the words into whatever is focused. Two ways in:
///
///   • **Push-to-talk** — hold the talk key (Right ⌥ by default). Starting a hold stops any playback (you're answering,
///     so the reply stops reading), release transcribes. A hold under `minUtterance` is treated
///     as accidental and dropped.
///   • **Hands-free** — armed by AppState when a Conversation Mode reply finishes reading and
///     the queue is empty. The mic opens, `VoiceActivityDetector` finds the turn, and the same
///     transcribe-and-paste path runs. No speech within the arm window closes the mic silently.
///
/// Yapper never presses Return. The transcript lands in the composer and sending is yours.
@MainActor
final class VoiceInputCoordinator: ObservableObject {

    enum Mode: Equatable, Sendable { case pushToTalk, handsFree }
    enum State: Equatable, Sendable {
        case idle
        case listening(Mode)
        case transcribing

        var isListening: Bool { if case .listening = self { return true } else { return false } }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var modelStatus: WhisperModelStatus = .notDownloaded
    @Published private(set) var microphoneStatus: MicrophonePermission.Status = .notDetermined

    /// The user started talking while something was playing — stop it.
    var onBargeIn: (() -> Void)?
    /// One-line status for the menu bar's last-event line.
    var onEvent: ((String) -> Void)?
    /// A transcript was pasted. Carries the text for logging / history hooks.
    var onDelivered: ((String) -> Void)?

    typealias TranscriberFactory = @MainActor (WhisperModel, @escaping @Sendable (WhisperModelStatus) -> Void) -> Transcribing

    private let settings: SettingsStore
    let vocabulary: VocabularyStore
    private let capture: AudioCapturing
    private let delivery: TextDelivering
    private let makeTranscriber: TranscriberFactory
    private let vadConfig: VoiceActivityDetector.Config
    /// Holds shorter than this are accidental (a slow ⌘-shortcut) — never transcribed.
    private let minUtterance: TimeInterval
    /// TCC lookup, injectable so tests aren't hostage to the runner's microphone grant.
    private let permissionStatus: @MainActor () -> MicrophonePermission.Status

    private var transcriber: Transcribing?
    private var vad: VoiceActivityDetector?
    private var listeningSince: Date?
    private var turnTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(settings: SettingsStore,
         vocabulary: VocabularyStore,
         capture: AudioCapturing,
         delivery: TextDelivering,
         makeTranscriber: @escaping TranscriberFactory,
         vadConfig: VoiceActivityDetector.Config = .init(),
         minUtterance: TimeInterval = 0.35,
         permissionStatus: @escaping @MainActor () -> MicrophonePermission.Status = { MicrophonePermission.status() }) {
        self.settings = settings
        self.vocabulary = vocabulary
        self.capture = capture
        self.delivery = delivery
        self.makeTranscriber = makeTranscriber
        self.vadConfig = vadConfig
        self.minUtterance = minUtterance
        self.permissionStatus = permissionStatus

        capture.onLevel = { [weak self] level in self?.handleLevel(level) }
        capture.onInterrupted = { [weak self] in self?.handleInterruption() }
    }

    // MARK: - Lifecycle

    /// Wire settings and pre-load the model so the first hold is instant. Call once at launch.
    func bootstrap() {
        refreshMicrophonePermission()
        settings.$whisperModelID
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.reloadTranscriber() }
            .store(in: &cancellables)
        settings.$voiceInputEnabled
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.reloadTranscriber() }
            .store(in: &cancellables)
        reloadTranscriber()
    }

    func refreshMicrophonePermission() {
        microphoneStatus = permissionStatus()
    }

    var model: WhisperModel { WhisperModel.named(settings.whisperModelID) }

    /// Drop the resident pipeline and build one for the current model. Loads it if the files
    /// are already on disk and Voice In is on; otherwise waits for `downloadModel()`.
    private func reloadTranscriber() {
        cancelTurn()
        transcriber = nil
        let model = self.model
        guard settings.voiceInputEnabled else {
            modelStatus = model.isDownloaded ? .downloaded : .notDownloaded
            return
        }
        if model.isDownloaded {
            prepare(model, announce: false)
        } else {
            modelStatus = .notDownloaded
        }
    }

    /// Settings → Download / Retry. Also the path that loads a model already on disk.
    func downloadModel() {
        guard !modelStatus.isBusy else { return }
        prepare(model, announce: true)
    }

    private func prepare(_ model: WhisperModel, announce: Bool) {
        let t = makeTranscriber(model) { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self, self.transcriber?.modelID == model.id else { return }
                self.modelStatus = status
            }
        }
        transcriber = t
        modelStatus = model.isDownloaded ? .loading : .downloading(progress: 0)
        Task { [weak self] in
            do {
                try await t.prepare()
                if announce { self?.onEvent?("Speech model ready") }
            } catch {
                Log.voice.error("Model prepare failed: \(error.localizedDescription, privacy: .public)")
                if announce { self?.onEvent?("Speech model failed: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: - Push-to-talk

    func beginPushToTalk() {
        guard settings.voiceInputEnabled else { return }
        if case .listening(.handsFree) = state { stopCapture(discard: true) }   // hold overrides
        guard state == .idle else { return }
        guard preflight(interactive: true) else { return }
        onBargeIn?()
        startListening(.pushToTalk)
    }

    func endPushToTalk() {
        guard case .listening(.pushToTalk) = state else { return }
        finishTurn(transcribe: true)
    }

    func cancelPushToTalk() {
        guard case .listening(.pushToTalk) = state else { return }
        stopCapture(discard: true)
    }

    // MARK: - Hands-free

    /// Open the mic and wait for the user to talk. Silent no-op when hands-free is off, Voice In
    /// is off, or the mic isn't ready — hands-free must never nag.
    func armHandsFree() {
        guard settings.voiceInputEnabled, settings.handsFreeEnabled, state == .idle else { return }
        guard preflight(interactive: false) else { return }
        startListening(.handsFree)
    }

    /// Playback started, Conversation Mode went off, or the user took over with a hold.
    func disarmHandsFree() {
        guard case .listening(.handsFree) = state else { return }
        stopCapture(discard: true)
    }

    // MARK: - Turn machinery

    /// Permission + model checks. `interactive` decides whether a failure talks to the user.
    private func preflight(interactive: Bool) -> Bool {
        refreshMicrophonePermission()
        switch microphoneStatus {
        case .granted: break
        case .notDetermined:
            let keycap = settings.yapperKey.keycap
            Task { [weak self] in
                let granted = await MicrophonePermission.request()
                self?.refreshMicrophonePermission()
                guard interactive else { return }
                self?.onEvent?(granted ? "Microphone granted — hold \(keycap) to talk" : "Microphone access denied")
            }
            return false
        case .denied:
            if interactive { onEvent?("Microphone denied — System Settings → Privacy → Microphone") }
            return false
        }
        guard transcriber != nil, modelStatus.isReady else {
            if interactive {
                switch modelStatus {
                case .downloading(let p): onEvent?("Downloading speech model… \(Int(p * 100))%")
                case .loading: onEvent?("Speech model loading…")
                case .failed(let msg): onEvent?("Speech model failed: \(msg)")
                default: onEvent?("Download a speech model in Settings → Conversation")
                }
            }
            return false
        }
        return true
    }

    private func startListening(_ mode: Mode) {
        do {
            try capture.start(deviceUID: settings.inputDeviceUID)
        } catch {
            // A vanished external mic shouldn't strand the feature — fall back to the default.
            if settings.inputDeviceUID != nil, (try? capture.start(deviceUID: nil)) != nil {
                Log.voice.notice("Selected microphone unavailable; using the default input")
            } else {
                Log.voice.error("Capture start failed: \(error.localizedDescription, privacy: .public)")
                if mode == .pushToTalk { onEvent?("Microphone failed: \(error.localizedDescription)") }
                return
            }
        }
        listeningSince = Date()
        vad = mode == .handsFree ? VoiceActivityDetector(config: vadConfig) : nil
        state = .listening(mode)
        onEvent?(mode == .pushToTalk ? "Listening… release to type" : "Listening…")
        Log.voice.info("Listening (\(mode == .pushToTalk ? "push-to-talk" : "hands-free", privacy: .public))")
        armWatchdog(for: mode)
    }

    private func handleLevel(_ level: Float) {
        guard case .listening(.handsFree) = state, var detector = vad else { return }
        let event = detector.process(level: level)
        vad = detector
        switch event {
        case .speechStarted?:
            Log.voice.debug("Hands-free: speech onset")
        case .turnEnded?:
            finishTurn(transcribe: true)
        case .timedOut?:
            Log.voice.info("Hands-free: nobody spoke; closing the mic")
            stopCapture(discard: true)
        case nil:
            break
        }
    }

    private func handleInterruption() {
        guard state.isListening else { return }
        finishTurn(transcribe: true)
    }

    /// The VAD only advances when audio arrives. If the tap goes silent (device yanked, engine
    /// wedged) nothing would ever close the mic — so a coarse timer backstops it.
    private func armWatchdog(for mode: Mode) {
        watchdog?.cancel()
        let ceiling = mode == .handsFree
            ? vadConfig.armTimeout + vadConfig.maxUtterance + 2
            : vadConfig.maxUtterance + 30
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ceiling))
            guard let self, !Task.isCancelled, self.state.isListening else { return }
            Log.voice.notice("Watchdog closed a mic that was open for \(Int(ceiling), privacy: .public)s")
            self.finishTurn(transcribe: mode == .pushToTalk)
        }
    }

    @discardableResult
    private func stopCapture(discard: Bool) -> [Float] {
        watchdog?.cancel()
        watchdog = nil
        let samples = capture.stop()
        vad = nil
        listeningSince = nil
        if discard { state = .idle }
        return samples
    }

    private func finishTurn(transcribe: Bool) {
        let heldFor = listeningSince.map { Date().timeIntervalSince($0) } ?? 0
        let samples = stopCapture(discard: !transcribe)
        guard transcribe else { return }
        let seconds = Double(samples.count) / AudioCapture.targetSampleRate
        guard seconds >= minUtterance, heldFor >= minUtterance else {
            state = .idle
            Log.voice.debug("Dropped a \(String(format: "%.2f", seconds), privacy: .public)s hold as accidental")
            return
        }
        guard let transcriber else { state = .idle; return }
        state = .transcribing
        onEvent?("Transcribing…")
        let prompt = TranscriptCorrector.prompt(terms: vocabulary.terms)
        let replacements = vocabulary.replacements
        turnTask = Task { [weak self] in
            defer { self?.state = .idle }
            do {
                let heard = try await transcriber.transcribe(samples: samples, prompt: prompt)
                guard !Task.isCancelled else { return }
                guard !heard.isEmpty else {
                    self?.onEvent?("Didn't catch that")
                    return
                }
                let text = TranscriptCorrector.apply(heard, replacements: replacements)
                try await self?.delivery.deliver(text)
                self?.vocabulary.record(original: heard, delivered: text)
                let words = text.split(whereSeparator: \.isWhitespace).count
                self?.onEvent?("Typed \(words) word\(words == 1 ? "" : "s") — press Return to send")
                self?.onDelivered?(text)
            } catch {
                Log.voice.error("Voice turn failed: \(error.localizedDescription, privacy: .public)")
                self?.onEvent?("Voice in failed: \(error.localizedDescription)")
            }
        }
    }

    private func cancelTurn() {
        if state.isListening { _ = stopCapture(discard: true) }
        turnTask?.cancel()
        turnTask = nil
    }
}
