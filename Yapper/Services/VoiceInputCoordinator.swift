import Foundation
import Combine

/// Runs one voice turn end to end: open the mic, decide when the turn is over, transcribe on
/// this Mac, paste the words into whatever is focused. Two ways in:
///
///   • **Push-to-talk** — hold the talk key (Right ⌥ by default). The mic opens at key-down and
///     the hold adopts that audio, so the first word isn't lost to the tap/hold decision.
///     Starting a hold stops any playback (you're answering, so the reply stops reading), release
///     transcribes after a short tail. A hold under `minUtterance` is treated as accidental.
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
    /// A talk hold locked with Space: the mic stays open after the key comes up, until the next
    /// press of the key.
    @Published private(set) var isLocked = false
    /// A locked dictation may run this long; a forgotten lock shouldn't record all afternoon.
    static let lockedCeiling: TimeInterval = 20 * 60
    @Published private(set) var modelStatus: WhisperModelStatus = .notDownloaded
    @Published private(set) var microphoneStatus: MicrophonePermission.Status = .notDetermined

    /// The user started talking while something was playing — stop it.
    var onBargeIn: (() -> Void)?
    /// One-line status for the menu bar's last-event line.
    var onEvent: ((String) -> Void)?
    /// A transcript was pasted. Carries the text and what it landed in, for the edit watcher.
    var onDelivered: ((String, DeliveryReceipt) -> Void)?
    /// Reads words off the focused window to bias this turn's decode. Nil leaves them out.
    var screenWords: (@MainActor () async -> [String])?
    /// The app and field the user was in when they started talking, so the paste goes back there.
    var captureTarget: (@MainActor () async -> DeliveryTarget?)?
    /// Lays out lists and applies self-corrections before the paste. Nil, or text returned
    /// unchanged, delivers the transcript as heard.
    var format: (@MainActor (String) async -> String)?

    typealias TranscriberFactory = @MainActor (WhisperModel, @escaping @Sendable (WhisperModelStatus) -> Void) -> Transcribing

    private let settings: SettingsStore
    let vocabulary: VocabularyStore
    private let capture: AudioCapturing
    private let delivery: TextDelivering
    private let makeTranscriber: TranscriberFactory
    private let vadConfig: VoiceActivityDetector.Config
    /// Holds shorter than this are accidental (a slow ⌘-shortcut) — never transcribed.
    private let minUtterance: TimeInterval
    /// Recording continues this long after the key comes up. People release as the last word
    /// ends, and the engine's final partial buffer would otherwise be thrown away with it.
    private let releaseTail: TimeInterval
    /// A mic that delivers nothing but exact zeros this long after opening is broken, not quiet
    /// (a room is never digitally silent). It gets one reopen before the user is told.
    private let silentStartTimeout: TimeInterval
    /// TCC lookup, injectable so tests aren't hostage to the runner's microphone grant.
    private let permissionStatus: @MainActor () -> MicrophonePermission.Status
    /// Where the latest recording is kept for Transcribe Again. Nil keeps nothing (tests).
    private let lastRecording: LastRecording?

    private var transcriber: Transcribing?
    private var vad: VoiceActivityDetector?
    private var listeningSince: Date?
    private var turnTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    /// The mic was opened at key-down, before anyone knows whether this press is a tap or a
    /// hold. A hold adopts the audio; anything else throws it away unheard.
    private var priming = false
    private var primeWatchdog: Task<Void, Never>?
    private var tailTask: Task<Void, Never>?
    /// This turn's screen words, read while the user talks so they cost the turn nothing.
    private var screenWordsTask: Task<[String], Never>?
    /// Where this turn's text goes, read when the turn started.
    private var targetTask: Task<DeliveryTarget?, Never>?
    /// When the user let go (or hands-free heard them stop): the start of the lag they feel.
    private var releasedAt: Date?
    /// Silent-start watch for the capture that is currently open.
    private var firstSilentLevelAt: Date?
    private var heardSignal = false
    private var reopenedForSilence = false
    private var cancellables: Set<AnyCancellable> = []

    init(settings: SettingsStore,
         vocabulary: VocabularyStore,
         capture: AudioCapturing,
         delivery: TextDelivering,
         makeTranscriber: @escaping TranscriberFactory,
         vadConfig: VoiceActivityDetector.Config = .init(),
         minUtterance: TimeInterval = 0.35,
         releaseTail: TimeInterval = 0.12,
         silentStartTimeout: TimeInterval = 0.5,
         permissionStatus: @escaping @MainActor () -> MicrophonePermission.Status = { MicrophonePermission.status() },
         lastRecording: LastRecording? = nil) {
        self.settings = settings
        self.vocabulary = vocabulary
        self.capture = capture
        self.delivery = delivery
        self.makeTranscriber = makeTranscriber
        self.vadConfig = vadConfig
        self.minUtterance = minUtterance
        self.releaseTail = releaseTail
        self.silentStartTimeout = silentStartTimeout
        self.permissionStatus = permissionStatus
        self.lastRecording = lastRecording

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

    /// The Yapper key went down. Whether this is a tap or a hold won't be known for 0.45 s, and
    /// waiting that long to open the mic cuts off the first word of every dictation. So the mic
    /// opens now, silently, and the press decides later. Skipped whenever opening it could be
    /// heard or felt: something is playing (the mic would hear Yapper's own voice), the input
    /// is a Bluetooth headset (it would drop into call quality), or Voice In isn't ready.
    func keyPressed(playbackActive: Bool) {
        guard settings.voiceInputEnabled, state == .idle, !priming, !playbackActive else { return }
        refreshMicrophonePermission()
        guard microphoneStatus == .granted, transcriber != nil, modelStatus.isReady else { return }
        guard !capture.isDisruptive(deviceUID: settings.inputDeviceUID) else { return }
        do {
            try capture.start(deviceUID: settings.inputDeviceUID)
        } catch {
            return   // the hold path opens the mic itself, with its fallback and its error message
        }
        priming = true
        listeningSince = Date()
        resetSilentWatch()
        primeWatchdog = Task { [weak self] in
            // A press that never resolves (an event tap hiccup) must not leave the mic open.
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, self.priming else { return }
            self.keyAbandoned()
        }
    }

    /// The press turned out to be a tap, a chord or a click. Throw the audio away unheard.
    func keyAbandoned() {
        guard priming else { return }
        priming = false
        primeWatchdog?.cancel()
        primeWatchdog = nil
        _ = capture.stop()
        listeningSince = nil
    }

    func beginPushToTalk() {
        guard settings.voiceInputEnabled else { return }
        if priming {
            // Adopt the audio recorded since key-down, so the turn starts when the key did.
            priming = false
            primeWatchdog?.cancel()
            primeWatchdog = nil
            onBargeIn?()
            state = .listening(.pushToTalk)
            readScreen()
            onEvent?("Listening… release to type")
            Log.voice.info("Listening (push-to-talk, mic open since key-down)")
            armWatchdog(for: .pushToTalk)
            return
        }
        if case .listening(.handsFree) = state { stopCapture(discard: true) }   // hold overrides
        guard state == .idle else { return }
        guard preflight(interactive: true) else { return }
        onBargeIn?()
        startListening(.pushToTalk)
    }

    /// Space during a hold. For the five-minute thought that shouldn't mean five minutes holding a key.
    func lock() {
        guard case .listening(.pushToTalk) = state, tailTask == nil, !isLocked else { return }
        isLocked = true
        armWatchdog(for: .pushToTalk, ceiling: Self.lockedCeiling)
        onEvent?("Mic locked — press \(settings.yapperKey.keycap) to finish")
        Log.voice.info("Mic locked")
    }

    /// The press that ends a locked dictation. Transcribes like a release.
    func finishLocked() {
        guard isLocked else { return }
        isLocked = false
        endPushToTalk()
    }

    func endPushToTalk() {
        guard !isLocked else { return }   // the key coming up after Space: keep listening
        guard case .listening(.pushToTalk) = state, tailTask == nil else { return }
        releasedAt = Date()
        guard releaseTail > 0 else { finishTurn(transcribe: true); return }
        tailTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.releaseTail ?? 0))
            guard let self else { return }
            self.tailTask = nil
            guard !Task.isCancelled, case .listening(.pushToTalk) = self.state else { return }
            self.finishTurn(transcribe: true)
        }
    }

    func cancelPushToTalk() {
        keyAbandoned()
        guard case .listening(.pushToTalk) = state else { return }
        tailTask?.cancel()
        tailTask = nil
        stopCapture(discard: true)
    }

    // MARK: - Hands-free

    /// Open the mic and wait for the user to talk. Silent no-op when hands-free is off, Voice In
    /// is off, or the mic isn't ready — hands-free must never nag.
    func armHandsFree() {
        guard settings.voiceInputEnabled, settings.handsFreeEnabled, state == .idle, !priming else { return }
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
        resetSilentWatch()
        vad = mode == .handsFree ? VoiceActivityDetector(config: vadConfig) : nil
        state = .listening(mode)
        readScreen()
        onEvent?(mode == .pushToTalk ? "Listening… release to type" : "Listening…")
        Log.voice.info("Listening (\(mode == .pushToTalk ? "push-to-talk" : "hands-free", privacy: .public))")
        armWatchdog(for: mode)
    }

    private func handleLevel(_ level: Float) {
        if priming || state.isListening { watchForSilentStart(level) }
        guard case .listening(.handsFree) = state, var detector = vad else { return }
        let event = detector.process(level: level)
        vad = detector
        switch event {
        case .speechStarted?:
            Log.voice.debug("Hands-free: speech onset")
        case .turnEnded?:
            releasedAt = Date()
            finishTurn(transcribe: true)
        case .timedOut?:
            Log.voice.info("Hands-free: nobody spoke; closing the mic")
            stopCapture(discard: true)
        case nil:
            break
        }
    }

    private func readScreen() {
        screenWordsTask?.cancel()
        targetTask = captureTarget.map { capture in Task { await capture() } }
        guard let screenWords else { screenWordsTask = nil; return }
        screenWordsTask = Task { await screenWords() }
    }

    // MARK: - Silent mic

    private func resetSilentWatch() {
        firstSilentLevelAt = nil
        heardSignal = false
        reopenedForSilence = false
    }

    /// Some devices open "successfully" and then deliver only zeros — a Bluetooth headset still
    /// switching profiles, an input another app grabbed. Everything said into that is lost, so
    /// reopen once; if the second open is silent too, say so instead of transcribing nothing.
    private func watchForSilentStart(_ level: Float) {
        guard !heardSignal else { return }
        if level > 1e-7 { heardSignal = true; return }
        let now = Date()
        guard let since = firstSilentLevelAt else { firstSilentLevelAt = now; return }
        guard now.timeIntervalSince(since) >= silentStartTimeout else { return }
        if reopenedForSilence {
            heardSignal = true   // stop watching; one warning per turn is enough
            Log.voice.notice("Mic still delivering silence after a reopen")
            onEvent?("Your mic is sending silence. Check the input in Settings → Conversation")
            return
        }
        reopenedForSilence = true
        firstSilentLevelAt = nil
        Log.voice.notice("Mic delivered only silence for \(Int(self.silentStartTimeout * 1000), privacy: .public)ms; reopening")
        _ = capture.stop()
        do {
            try capture.start(deviceUID: settings.inputDeviceUID)
        } catch {
            if (try? capture.start(deviceUID: nil)) == nil {
                Log.voice.error("Mic reopen failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if case .listening(.handsFree) = state { vad = VoiceActivityDetector(config: vadConfig) }
    }

    // MARK: - Re-paste

    /// Yapper key + V: type the last transcript again. The way back when a paste missed, landed
    /// in the wrong field, or got cleared.
    func repasteLast() {
        guard state == .idle, !priming else { return }
        guard let text = vocabulary.lastTranscript?.delivered, !text.isEmpty else {
            onEvent?("Nothing to paste yet")
            return
        }
        Task { [weak self] in
            do {
                try await self?.delivery.deliver(text)
                self?.onEvent?("Pasted your last transcript again")
            } catch {
                self?.onEvent?(error.localizedDescription)
            }
        }
    }

    private func handleInterruption() {
        if priming { keyAbandoned(); return }   // a hold now opens the new route fresh
        guard state.isListening else { return }
        finishTurn(transcribe: true)
    }

    /// The VAD only advances when audio arrives. If the tap goes silent (device yanked, engine
    /// wedged) nothing would ever close the mic — so a coarse timer backstops it.
    private func armWatchdog(for mode: Mode, ceiling override: TimeInterval? = nil) {
        watchdog?.cancel()
        let ceiling = override ?? (mode == .handsFree
            ? vadConfig.armTimeout + vadConfig.maxUtterance + 2
            : vadConfig.maxUtterance + 30)
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ceiling))
            guard let self, !Task.isCancelled, self.state.isListening else { return }
            Log.voice.notice("Watchdog closed a mic that was open for \(Int(ceiling), privacy: .public)s")
            self.finishTurn(transcribe: mode == .pushToTalk)
        }
    }

    @discardableResult
    private func stopCapture(discard: Bool) -> [Float] {
        isLocked = false
        watchdog?.cancel()
        watchdog = nil
        let samples = capture.stop()
        vad = nil
        listeningSince = nil
        if discard {
            state = .idle
            screenWordsTask?.cancel()
            screenWordsTask = nil
        }
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
        let screenTask = screenWordsTask
        screenWordsTask = nil
        let target = targetTask
        targetTask = nil
        let released = releasedAt ?? Date()
        releasedAt = nil
        let store = lastRecording
        turnTask = Task { [weak self] in
            // Kept alongside the decode, so one that fails or crashes can be run again.
            let saving = Task { await store?.save(samples) }
            await self?.transcribeAndDeliver(samples, using: transcriber, screenTask: screenTask,
                                             targetTask: target, releasedAt: released)
            await saving.value
            self?.state = .idle
        }
    }

    var hasLastRecording: Bool { lastRecording?.exists ?? false }

    /// Menu → Transcribe Last Recording Again: the same decode, correction and paste, run on
    /// the kept recording. The screen words are read now, from wherever the paste will land.
    func transcribeLastAgain() {
        guard state == .idle, !priming else { return }
        guard let store = lastRecording, store.exists else {
            onEvent?("No recording to transcribe yet")
            return
        }
        guard let transcriber, modelStatus.isReady else {
            onEvent?("Speech model isn't ready yet")
            return
        }
        state = .transcribing
        onEvent?("Transcribing your last recording again…")
        readScreen()
        let screenTask = screenWordsTask
        screenWordsTask = nil
        turnTask = Task { [weak self] in
            if let samples = await store.load(), !samples.isEmpty {
                await self?.transcribeAndDeliver(samples, using: transcriber, screenTask: screenTask)
            } else {
                self?.onEvent?("Couldn't open the last recording")
            }
            self?.state = .idle
        }
    }

    private func transcribeAndDeliver(_ samples: [Float], using transcriber: Transcribing,
                                      screenTask: Task<[String], Never>?,
                                      targetTask: Task<DeliveryTarget?, Never>? = nil,
                                      releasedAt: Date? = nil) async {
        let decodeStarted = Date()
        let terms = vocabulary.terms
        let replacements = vocabulary.replacements
        let againHint = lastRecording == nil ? "" : ". Menu → Transcribe Last Recording Again to retry"
        do {
            // Bounded by the walk's own time budget, and long finished on all but the
            // shortest holds.
            let screen = await screenTask?.value ?? []
            let prompt = TranscriptCorrector.prompt(terms: terms, screenWords: screen)
            if !screen.isEmpty { Log.voice.info("\(screen.count, privacy: .public) words from the screen for respelling") }
            let heard = try await transcriber.transcribe(samples: samples, prompt: prompt)
            let decoded = Date()
            guard !Task.isCancelled else { return }
            guard !heard.isEmpty else {
                onEvent?("Didn't catch that" + againHint)
                return
            }
            let corrected = TranscriptCorrector.apply(heard, replacements: replacements)
            let respelled = TranscriptCorrector.respell(corrected, candidates: screen + terms) {
                WordKnowledge.isDictionaryWord($0)
            }
            // "at 401" → "at 4:01": Whisper writes spoken times as plain numbers.
            let timed = SpokenTimes.normalize(respelled)
            let text = await format?(timed) ?? timed
            guard !Task.isCancelled else { return }
            guard !text.isEmpty else {   // nothing but "um"
                onEvent?("Didn't catch that" + againHint)
                return
            }
            let formatted = Date()
            let target = await targetTask?.value
            let receipt: DeliveryReceipt
            do {
                receipt = try await delivery.deliver(text, target: target)
            } catch PasteDelivery.DeliveryError.notPasted {
                // The words survived on the clipboard; say so instead of "failed".
                vocabulary.record(original: heard, delivered: text)
                onEvent?(PasteDelivery.DeliveryError.notPasted.errorDescription ?? "")
                return
            }
            vocabulary.record(original: heard, delivered: text)
            if let releasedAt, let shown = receipt.readAt {
                // .notice: the lag the user feels, end to end, broken into its stages.
                let ms = { (a: Date, b: Date) in Int(b.timeIntervalSince(a) * 1000) }
                Log.voice.notice("Turn: released → text on screen \(ms(releasedAt, shown), privacy: .public)ms (tail+stop \(ms(releasedAt, decodeStarted), privacy: .public), transcribe \(ms(decodeStarted, decoded), privacy: .public), tidy \(ms(decoded, formatted), privacy: .public), paste \(ms(formatted, shown), privacy: .public))")
            }
            let words = text.split(whereSeparator: \.isWhitespace).count
            onEvent?("Typed \(words) word\(words == 1 ? "" : "s") — press Return to send")
            onDelivered?(text, receipt)
        } catch {
            Log.voice.error("Voice turn failed: \(error.localizedDescription, privacy: .public)")
            onEvent?("Voice in failed: \(error.localizedDescription)" + againHint)
        }
    }

    private func cancelTurn() {
        keyAbandoned()
        tailTask?.cancel()
        tailTask = nil
        if state.isListening { _ = stopCapture(discard: true) }
        turnTask?.cancel()
        turnTask = nil
        screenWordsTask?.cancel()
        screenWordsTask = nil
    }
}
