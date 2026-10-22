import Foundation
import Combine
import AppKit

/// Single source of truth for runtime state shared across menu bar, mini player, and settings.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    /// True while any engine is speaking — drives the menu bar icon animation.
    /// Derived from TTSCoordinator activity in `wireReadingIndicator`; never set by hand.
    @Published var isReading: Bool = false
    @Published var conversationModeEnabled: Bool = false
    @Published var activeVoice: VoicePreset = .defaultPreset {
        // Persist the selection; restored in bootstrap(). Without this the choice lived only in
        // memory and every relaunch silently reset the voice to the default preset.
        didSet { settings.activeVoiceID = activeVoice.id }
    }
    @Published var hasAccessibilityPermission: Bool = false
    @Published var hasMicrophonePermission: Bool = false
    /// Mirrors the Voice In coordinator so the menu bar icon and Settings observe one object.
    @Published var voiceInputState: VoiceInputCoordinator.State = .idle
    @Published var whisperModelStatus: WhisperModelStatus = .notDownloaded
    @Published var lastEvent: String = ""
    @Published var currentReading: ReadingItem?
    /// Liner notes (the transcript panel) are showing. Lives here rather than in the player view
    /// because both the deck and the panel controller need it: the deck lights its TRANSCRIPT
    /// marking from it, the controller shows/hides the panel off it.
    @Published var transcriptVisible: Bool = false
    /// Set by the menu bar "History" item to deep-link the Settings window to the History tab.
    @Published var pendingHistoryOpen: Bool = false
    /// Set by Settings → Hotkeys to reopen the first-run guide on demand.
    @Published var pendingOnboardingOpen: Bool = false

    /// Fires every time a Yapper-key gesture is recognised, regardless of what it went on to do.
    /// The first-run guide listens here to confirm the user actually performed the gesture —
    /// the read that follows can legitimately fail (nothing selected, unsupported app) without
    /// meaning they got the keystroke wrong.
    let hotkeyFired = PassthroughSubject<HotkeyGesture, Never>()

    enum HotkeyGesture {
        case readLatestOrToggle, readSelection, conversationMode, skipNext, dumpAXTree, pushToTalk
    }

    let settings = SettingsStore()
    let keychain = Keychain(service: "app.yapper.Yapper")
    let hotkeys = HotkeyManager()
    let history = HistoryStore()
    lazy var tts = TTSCoordinator(keychain: keychain, settings: settings)
    lazy var conversationWatcher = ConversationWatcher(settings: settings)
    let vocabulary = VocabularyStore()
    let media = MediaController()
    let editWatcher = EditWatcher()
    let formatter = SmartFormatter()
    /// The clickable note under the pill: a learned word, a missed paste.
    let toast = VoiceToastPresenter()
    /// Every dictation, for Settings → Dictations. Not the read-aloud `history`.
    let dictations = DictationHistoryStore()
    let snippets = SnippetStore()
    private lazy var sounds = DictationSounds()
    private(set) var recordingHUD: RecordingHUDController?
    /// The Loud Mouth's live read of the mic, fed by `mic` while the pill shows the mouth.
    let mouthLive = MouthLive()
    private let mic = AudioCapture()
    /// The Yapper key press that finished a locked dictation; its tap or hold is spent.
    private var pressEndedLockedDictation = false
    lazy var voiceInput = VoiceInputCoordinator(
        settings: settings,
        vocabulary: vocabulary,
        capture: mic,
        delivery: PasteDelivery(),
        makeTranscriber: { model, onStatus in
            switch model.engine {
            case .parakeet: ParakeetTranscriber(model: model, onStatus: onStatus)
            case .whisper: WhisperTranscriber(model: model, onStatus: onStatus)
            }
        },
        lastRecording: LastRecording()
    )

    private var conversationModeCancellable: AnyCancellable?
    private var voiceInputCancellables: Set<AnyCancellable> = []
    /// True from the moment a Conversation Mode reply starts playing until playback goes idle.
    /// Hands-free listening arms only on that idle transition — never after a manual read.
    private var conversationReadActive = false
    private var readingIndicatorCancellable: AnyCancellable?
    private var permissionPoll: Timer?
    private var historyPruneTimer: Timer?
    private var lastHotkeyTapAt: Date?
    private var readLatestInFlight = false
    /// Deferred resume so a double-tap's first tap doesn't blip the old audio (see wireHotkeys).
    private var pendingResumeTask: Task<Void, Never>?

    /// Two taps within this window = double-tap (force a fresh Read Latest).
    private static let doubleTapWindow: TimeInterval = 0.45

    private init() {}

    func bootstrap() {
        Log.app.info("Yapper bootstrap")
        if let saved = (VoicePreset.presets + settings.customVoices)
            .first(where: { $0.id == settings.activeVoiceID }) {
            activeVoice = saved
        }
        history.prune(retentionHours: settings.historyRetentionHours)
        dictations.prune(retention: settings.dictationRetention)
        dictations.sweepOrphanAudio()
        startHistoryPruneTimer()
        wireReadingIndicator()
        wireHotkeys()
        hasAccessibilityPermission = AccessibilityPermission.isGranted()
        Log.app.info("AX permission granted: \(self.hasAccessibilityPermission, privacy: .public)")
        if hasAccessibilityPermission {
            hotkeys.install()
        } else {
            // Spec: prompt with the system dialog on first launch. Then poll so hotkeys and
            // Conversation Mode come alive the moment permission lands — no relaunch required.
            AccessibilityPermission.requestIfNeeded(prompt: true)
            startPermissionPolling()
        }
        wireConversationMode()
        wireVoiceInput()
    }

    // MARK: - Media pause

    private var mediaGate = MediaResumeGate()
    /// How long a pause sent at key-down takes to silence the other app: the audio the mic
    /// takes in before then is dropped from the dictation.
    static let mediaPauseLag: TimeInterval = 0.15
    private var mediaResumeTask: Task<Void, Never>?

    /// Re-decide when paused media comes back. Publishers fire before their property updates,
    /// so the caller passes the value that just changed.
    private func reconsiderMediaResume(voiceState: VoiceInputCoordinator.State? = nil,
                                       yapperReading: Bool? = nil, queued: Int? = nil) {
        mediaResumeTask?.cancel()
        mediaResumeTask = nil
        guard media.isHoldingPause else { return }
        let voiceBusy = (voiceState ?? voiceInput.state) != .idle
        let speaking = (yapperReading ?? (tts.active != nil)) || (queued ?? tts.queueCount) > 0
        guard let at = mediaGate.resumeTime(voiceBusy: voiceBusy, yapperSpeaking: speaking, now: Date()) else { return }
        mediaResumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, at.timeIntervalSinceNow)))
            guard let self, !Task.isCancelled else { return }
            self.mediaGate.awaitingReplyUntil = nil
            self.media.resumeIfPaused()
        }
    }

    // MARK: - Voice In

    private func wireVoiceInput() {
        voiceInput.onBargeIn = { [weak self] in
            guard let self, self.tts.active != nil else { return }
            self.tts.stop()   // you're answering — the reply stops reading, queue included
        }
        voiceInput.onEvent = { [weak self] in self?.lastEvent = $0 }
        voiceInput.onDelivered = { [weak self] text, receipt in
            Log.voice.info("Delivered \(text.count, privacy: .public) chars to the focused app")
            guard let self else { return }
            if self.settings.learnFromEdits { self.editWatcher.watch(receipt, delivered: receipt.text.isEmpty ? text : receipt.text) }
            guard self.conversationModeEnabled else { return }
            self.mediaGate.awaitingReplyUntil = Date().addingTimeInterval(MediaResumeGate.replyWait)
        }
        voiceInput.captureTarget = { await DeliveryTarget.current() }
        voiceInput.screenWords = { [weak self] in
            guard let self else { return .empty }
            let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let words = self.settings.useScreenWords
            let code = self.settings.codeWords && CodeWords.isCodingApp(bundleID: bundleID)
            guard words || code else { return .empty }
            let text = await ScreenVocabulary.visibleText()
            return ScreenReading(
                words: words ? ScreenVocabulary.candidates(in: text) { WordKnowledge.isDictionaryWord($0) } : [],
                identifiers: code ? CodeWords.identifiers(in: text) : [],
                tagsFiles: code && CodeWords.tagsFiles(bundleID: bundleID))
        }
        voiceInput.format = { [weak self] text in
            guard let self else { return text }
            let cleanup = self.settings.cleanUpSpeech
            let tidied = cleanup ? Disfluency.clean(text) : text
            let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let mode = FormatMode.forApp(bundleID: bundleID)
            // "First, … second, …" is laid out by rule: reliable where the model is a coin flip.
            if let listed = SpokenLists.format(tidied, mode: mode) { return Punctuation.finish(listed, mode: mode) }
            guard self.settings.smartFormattingEnabled, !tidied.isEmpty else { return Punctuation.finish(tidied, mode: mode) }
            let formatted = await self.formatter.format(tidied, bundleID: bundleID, cleanup: cleanup)
            return Punctuation.finish(formatted, mode: mode)
        }
        voiceInput.expandSnippets = { [weak self] text in self?.snippets.expand(text) ?? text }
        recordingHUD = RecordingHUDController(state: self)
        voiceInput.onLevel = { [weak self] in self?.recordingHUD?.level($0) }
        // The mouth hears the mic only when the pill is on and shows it; it takes effect from the
        // next time the mic opens.
        settings.$pillStyle.combineLatest(settings.$dictationHUD)
            .sink { [weak self] style, hud in
                guard let self else { return }
                self.mic.mouthFeed = (hud && style == .mouth) ? self.mouthLive : nil
                if hud && style == .mouth {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1))
                        MouthStage.shared.warmUp()            // compile its shaders before the first open
                    }
                }
            }
            .store(in: &voiceInputCancellables)
        if settings.dictationSounds { _ = sounds }   // render the sounds now, not on the first hold
        voiceInput.playStartCue = { [weak self] in
            guard let self, self.settings.dictationSounds else { return nil }
            return self.sounds.playStart(mouth: self.mouthOnShow)
        }
        voiceInput.stopStartCue = { [weak self] in
            guard let self, self.settings.dictationSounds else { return }
            self.sounds.stopStart()
        }
        voiceInput.onTurnFinished = { [weak self] in self?.turnFinished($0) }
        voiceInput.onPasteLanded = { [weak self] in self?.pasteLanded() }
        editWatcher.onLearned = { [weak self] learned in
            guard let self else { return }
            self.vocabulary.applyLearned(learned)
            let names = learned.map { "“\($0.typed)”" }.joined(separator: ", ")
            self.lastEvent = "Learned \(names) from your edit"
            if self.settings.dictationHUD { self.toast.learned(learned.map(\.typed)) }
        }
        toast.onUndoLearned = { [weak self] in self?.vocabulary.undoLearned() }
        toast.onPaste = { [weak self] text in await self?.voiceInput.pasteAgain(text) ?? false }
        voiceInput.$state.sink { [weak self] in self?.voiceInputState = $0 }.store(in: &voiceInputCancellables)

        // Other apps' media pauses while the user talks or Yapper reads, and comes back once
        // both are done (MediaResumeGate decides when).
        media.start()
        voiceInput.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                if state == .listening(.pushToTalk), self.settings.pauseMediaWhileTalking {
                    self.media.pauseIfPlaying()
                }
                // A new dictation ends the watch on the last one: learn from what's there now.
                if state.isListening {
                    self.toast.close()
                    self.editWatcher.finish()
                    if self.settings.smartFormattingEnabled {
                        self.formatter.warmUp(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                                              cleanup: self.settings.cleanUpSpeech)
                    }
                }
                self.reconsiderMediaResume(voiceState: state)
            }
            .store(in: &voiceInputCancellables)
        tts.$active
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] reading in
                guard let self else { return }
                if reading {
                    self.mediaGate.awaitingReplyUntil = nil   // the reply arrived
                    if self.settings.pauseMediaWhileTalking { self.media.pauseIfPlaying() }
                }
                self.reconsiderMediaResume(yapperReading: reading)
            }
            .store(in: &voiceInputCancellables)
        tts.$queueCount
            .removeDuplicates()
            .sink { [weak self] in self?.reconsiderMediaResume(queued: $0) }
            .store(in: &voiceInputCancellables)
        voiceInput.$modelStatus.sink { [weak self] in self?.whisperModelStatus = $0 }.store(in: &voiceInputCancellables)
        voiceInput.$microphoneStatus
            .map { $0 == .granted }
            .sink { [weak self] in self?.hasMicrophonePermission = $0 }
            .store(in: &voiceInputCancellables)

        // Hands-free: the mic opens when a conversation reply finishes and nothing is queued.
        // Any playback starting closes it again so the speakers never feed the mic.
        tts.$active
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] playing in
                guard let self else { return }
                if playing {
                    self.voiceInput.disarmHandsFree()
                } else if self.conversationReadActive {
                    self.conversationReadActive = false
                    if self.conversationModeEnabled, self.tts.queueCount == 0 {
                        self.voiceInput.armHandsFree()
                    }
                }
            }
            .store(in: &voiceInputCancellables)

        hotkeys.key = settings.yapperKey
        hotkeys.skipIsMeaningful = { [weak self] in
            guard let self else { return false }
            return self.tts.active != nil || self.tts.queueCount > 0
        }
        hotkeys.shortcuts = settings.customShortcuts
        settings.$customShortcuts
            .sink { [weak self] in self?.hotkeys.shortcuts = $0 }
            .store(in: &voiceInputCancellables)
        settings.$yapperKey
            .removeDuplicates()
            .sink { [weak self] key in
                self?.hotkeys.key = key
                self?.voiceInput.cancelPushToTalk()   // a hold in flight on the old key is void
            }
            .store(in: &voiceInputCancellables)

        voiceInput.bootstrap()
    }

    /// The words just appeared: the pill closes and the done sound plays now, not once the
    /// clipboard has been put back.
    private func pasteLanded() {
        recordingHUD?.finish(.pasted)
        if settings.dictationSounds { sounds.playDone(mouth: mouthOnShow) }
    }

    /// The Loud Mouth is the pill: its sounds play instead of the chimes, in step with its face.
    /// Parked 2026-10-22: the user kept the chimes. Flip `mouthSounds` to hear them again.
    private var mouthOnShow: Bool { Self.mouthSounds && settings.dictationHUD && settings.pillStyle == .mouth }
    private static let mouthSounds = false

    /// A voice turn ended: tell the HUD, play the sound (a paste already had its own when it
    /// landed), and keep it in Dictations. Everything here runs after the paste, so none of it
    /// adds to the lag.
    private func turnFinished(_ report: TurnReport) {
        recordingHUD?.finish(report.outcome)
        if case .copied = report.outcome, settings.dictationHUD { toast.missedPaste(report.text) }
        if settings.dictationSounds {
            switch report.outcome {
            case .pasted: break
            // The mouth grimaces at a missed paste, so it sounds like it too.
            case .copied: if mouthOnShow { sounds.playFailed(mouth: true) } else { sounds.playDone(mouth: false) }
            case .empty, .failed: sounds.playFailed(mouth: mouthOnShow)
            }
        }
        guard settings.dictationRetention != .never else { return }
        let app = report.target.flatMap { NSRunningApplication(processIdentifier: $0.pid) }
        let outcome: Dictation.Outcome
        var error: String?
        switch report.outcome {
        case .pasted: outcome = .pasted
        case .copied: outcome = .copied
        case .empty: outcome = .empty
        case .failed(let why): outcome = .failed; error = why
        }
        dictations.record(Dictation(at: report.startedAt,
                                    appName: report.target?.appName ?? app?.localizedName,
                                    bundleID: app?.bundleIdentifier,
                                    heard: report.heard, text: report.text,
                                    duration: Double(report.samples.count) / AudioCapture.targetSampleRate,
                                    outcome: outcome, modelID: report.modelID, error: error),
                          samples: settings.keepDictationAudio ? report.samples : nil)
    }

    /// Settings → Dictations → Paste. Settings steps aside first, so the words land in the app
    /// you were in rather than in the Settings window.
    func pasteDictation(_ text: String) {
        NSApp.hide(nil)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.voiceInput.paste(text, announce: "Pasted that dictation again")
        }
    }

    /// Settings → Dictations → Transcribe again: runs the kept recording through the current
    /// speech model and pipeline and updates the entry. No paste. Returns an error to show.
    func retranscribe(_ entry: Dictation) async -> String? {
        guard let samples = await dictations.loadAudio(for: entry), !samples.isEmpty else {
            return "The recording isn't kept any more."
        }
        do {
            let result = try await voiceInput.transcribe(samples: samples)
            dictations.update(entry.id, heard: result.heard, text: result.text,
                              outcome: result.text.isEmpty ? .empty
                                  : entry.outcome == .pasted || entry.outcome == .copied ? entry.outcome : .retried,
                              modelID: voiceInput.model.id)
            return result.text.isEmpty ? "Still nothing to type in that one." : nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Yapper runs for weeks at a time, so the retention window has to be enforced continuously —
    /// not just at launch. Hourly with generous tolerance; pruning is cheap.
    private func startHistoryPruneTimer() {
        let t = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.history.prune(retentionHours: self.settings.historyRetentionHours)
                self.dictations.prune(retention: self.settings.dictationRetention)
            }
        }
        t.tolerance = 300
        historyPruneTimer = t
    }

    /// The menu bar icon animates while ANY engine is speaking — manual read, selection,
    /// conversation queue, replay, or preview. Deriving it from the coordinator means it can
    /// never stick on after a read finishes.
    private func wireReadingIndicator() {
        readingIndicatorCancellable = tts.$active
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] speaking in self?.isReading = speaking }
    }

    // MARK: - Conversation Mode

    private func wireConversationMode() {
        conversationWatcher.onResponseCompleted = { [weak self] pending in
            self?.handleCompletedResponse(pending)
        }
        conversationModeCancellable = $conversationModeEnabled
            .removeDuplicates()
            .sink { [weak self] on in self?.setConversationMode(on) }
        if settings.conversationDefaultOn {
            conversationModeEnabled = true   // triggers the sink → starts the watcher
        }
    }

    private func setConversationMode(_ on: Bool) {
        if on {
            guard hasAccessibilityPermission else {
                lastEvent = "Grant Accessibility to use Conversation Mode"
                conversationModeEnabled = false
                return
            }
            conversationWatcher.start()
            lastEvent = "Conversation Mode ON"
        } else {
            conversationWatcher.stop()
            tts.clearQueue()   // stop queuing; the current item plays out
            voiceInput.disarmHandsFree()
            conversationReadActive = false
            lastEvent = "Conversation Mode OFF"
        }
    }

    /// Heavy extraction + enqueue for a response the watcher confirmed is complete.
    /// The copy-press (AXPress + clipboard poll, up to ~1.5s) runs on AXWorker so the main thread
    /// never hitches; on failure the watcher un-marks the response and retries with a fresh probe.
    private func handleCompletedResponse(_ pending: ConversationWatcher.PendingResponse) {
        guard conversationModeEnabled else { return }
        Task { [weak self] in
            guard let self else { return }
            let raw: String
            do {
                raw = try await AccessibilityReader.extractText(from: pending.copyButton)
            } catch {
                Log.ax.error("Conversation extract failed: \(error.localizedDescription, privacy: .public)")
                self.conversationWatcher.retryFailedExtraction(pending)
                return
            }
            self.enqueueCompletedResponse(pending, raw: raw)
        }
    }

    private func enqueueCompletedResponse(_ pending: ConversationWatcher.PendingResponse, raw: String) {
        guard conversationModeEnabled else { return }   // may have been toggled off mid-extraction
        let cleaned = TextCleaner.clean(raw)
        guard !cleaned.isEmpty else { return }
        let item = ReadingItem.make(sourceApp: pending.sourceApp, cleaned: cleaned, raw: raw)
        // currentReading + history are set in onStarted (when it actually begins playing), so
        // queued-but-not-yet-playing items don't flash the player or pollute history early.
        tts.enqueue(item, voice: activeVoice) { [weak self] url in
            guard let self else { return }
            self.conversationReadActive = true
            self.currentReading = item
            self.lastEvent = "Speaking from \(pending.sourceApp)"
            self.history.record(item: item, voiceID: self.activeVoice.id,
                                audioFileName: url?.lastPathComponent, origin: .conversation)
        }
    }

    /// Replay a history entry: reuse its cached audio if present, otherwise re-synthesize.
    func replay(_ entry: HistoryEntry) {
        let item = ReadingItem(id: UUID(),
                               sourceApp: entry.sourceApp,
                               createdAt: Date(),
                               cleanedText: entry.cleanedText,
                               rawText: entry.rawText)
        conversationReadActive = false
        if let fileURL = history.audioURL(for: entry) {
            tts.replay(fileURL: fileURL, text: entry.cleanedText)
            currentReading = item
            lastEvent = "Replaying from \(entry.sourceApp)"
        } else {
            let voice = resolveVoice(entry.voiceID)
            currentReading = item
            tts.speak(item.cleanedText, voice: voice)
            lastEvent = "Re-reading from \(entry.sourceApp)"
        }
    }

    private func resolveVoice(_ id: String) -> VoicePreset {
        (VoicePreset.presets + settings.customVoices).first { $0.id == id } ?? activeVoice
    }

    // MARK: - Accessibility permission

    /// Cheap re-check — called when the menu opens and by the poller. Detects the false→true
    /// transition so a grant made in System Settings takes effect without a relaunch.
    func refreshPermissionState() {
        let granted = AccessibilityPermission.isGranted()
        let becameGranted = granted && !hasAccessibilityPermission
        hasAccessibilityPermission = granted
        Log.app.info("AX permission granted: \(granted, privacy: .public)")
        if becameGranted {
            handlePermissionGranted()
        } else if !granted {
            startPermissionPolling()
        }
    }

    /// Permission landed while running — bring everything that was blocked on it to life.
    private func handlePermissionGranted() {
        stopPermissionPolling()
        hotkeys.install()   // no-op if already installed; retries the failed event tap otherwise
        lastEvent = "Accessibility granted — hotkeys active"
        if settings.conversationDefaultOn, !conversationModeEnabled {
            conversationModeEnabled = true   // the sink starts the watcher
        }
    }

    /// AXIsProcessTrusted() is a cheap TCC check; poll while unauthorized so the grant is picked
    /// up within seconds even if the user never reopens the menu.
    private func startPermissionPolling() {
        guard permissionPoll == nil else { return }
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.hasAccessibilityPermission else { return }
                if AccessibilityPermission.isGranted() { self.refreshPermissionState() }
            }
        }
    }

    private func stopPermissionPolling() {
        permissionPoll?.invalidate()
        permissionPoll = nil
    }

    /// Read the latest assistant response from the frontmost app and speak it, superseding any
    /// current playback. Re-entry while a previous read is still extracting is ignored.
    private func performReadLatest() {
        guard !readLatestInFlight else { return }
        readLatestInFlight = true
        conversationReadActive = false
        lastEvent = "Reading…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.readLatestInFlight = false }
            do {
                let result = try await AccessibilityReader.readLatest()
                let cleaned = TextCleaner.clean(result.text)
                let item = ReadingItem.make(sourceApp: result.sourceApp, cleaned: cleaned, raw: result.text)
                self.currentReading = item
                self.lastEvent = "Speaking \(cleaned.count) chars from \(result.sourceApp)"
                Log.ax.info("Read raw=\(result.text.count) cleaned=\(cleaned.count) from \(result.sourceApp, privacy: .public)")
                let audioURL = self.tts.speak(cleaned, voice: self.activeVoice)
                self.history.record(item: item,
                                    voiceID: self.activeVoice.id,
                                    audioFileName: audioURL?.lastPathComponent,
                                    origin: .latest)
            } catch {
                self.lastEvent = "Read failed: \(error.localizedDescription)"
                Log.ax.error("Read failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func wireHotkeys() {
        hotkeys.onReadLatestOrToggle = { [weak self] in
            guard let self else { return }
            if self.pressEndedLockedDictation { self.pressEndedLockedDictation = false; return }
            self.hotkeyFired.send(.readLatestOrToggle)
            // Double-tap: force a fresh Read Latest of the CURRENT window, superseding whatever
            // is playing or paused. Without this, tapping after a pause always resumes the old
            // audio — even when you've moved to a different conversation and want that one read.
            let now = Date()
            let isDoubleTap = self.lastHotkeyTapAt.map { now.timeIntervalSince($0) < Self.doubleTapWindow } ?? false
            self.lastHotkeyTapAt = now
            if isDoubleTap {
                self.pendingResumeTask?.cancel()
                self.pendingResumeTask = nil
                Log.hotkey.info("Yapper key double-tap -> Force Read Latest")
                self.performReadLatest()
                return
            }
            // Single tap while playing: pause. Instant — this is the "someone's talking to me"
            // gesture, so it must never wait on the double-tap window.
            if self.tts.isPlaying {
                self.tts.pauseOrResume()
                self.lastEvent = "Paused"
                Log.hotkey.info("Yapper key tap -> Pause")
                return
            }
            // Single tap while paused: resume — but only after the double-tap window has passed.
            // If the resume fired immediately, a double-tap's first tap would blip the old audio,
            // and a slightly-slow double-tap would just toggle pause twice (looks like a no-op).
            if self.tts.active != nil {
                self.pendingResumeTask?.cancel()
                self.pendingResumeTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(Self.doubleTapWindow))
                    guard let self, !Task.isCancelled else { return }
                    self.pendingResumeTask = nil
                    self.tts.pauseOrResume()
                    self.lastEvent = "Resumed"
                    Log.hotkey.info("Yapper key tap -> Resume")
                }
                return
            }
            Log.hotkey.info("Yapper key tap -> Read Latest")
            self.performReadLatest()
        }
        hotkeys.onReadSelection = { [weak self] in
            guard let self else { return }
            self.hotkeyFired.send(.readSelection)
            // If something is already playing, treat this gesture as "replace with selection" —
            // stop current playback first.
            self.conversationReadActive = false
            if self.tts.active != nil { self.tts.stop() }

            self.lastEvent = "Reading selection…"
            Log.hotkey.info("Yapper key+S -> Read Selection")

            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let result = try await AccessibilityReader.readSelection()
                    let cleaned = TextCleaner.clean(result.text)
                    let item = ReadingItem.make(sourceApp: result.sourceApp, cleaned: cleaned, raw: result.text)
                    self.currentReading = item
                    self.lastEvent = "Speaking \(cleaned.count) chars from \(result.sourceApp) selection"
                    Log.ax.info("Selection raw=\(result.text.count) cleaned=\(cleaned.count) from \(result.sourceApp, privacy: .public)")
                    let audioURL = self.tts.speak(cleaned, voice: self.activeVoice)
                    self.history.record(item: item,
                                        voiceID: self.activeVoice.id,
                                        audioFileName: audioURL?.lastPathComponent,
                                        origin: .selection)
                } catch {
                    self.lastEvent = "Selection failed: \(error.localizedDescription)"
                    Log.ax.error("Selection failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        hotkeys.onToggleConversationMode = { [weak self] in
            guard let self else { return }
            self.hotkeyFired.send(.conversationMode)
            self.conversationModeEnabled.toggle()
            self.lastEvent = "Conversation Mode -> \(self.conversationModeEnabled ? "ON" : "OFF")"
            Log.hotkey.info("Yapper key+Enter -> Conversation Mode \(self.conversationModeEnabled, privacy: .public)")
        }
        hotkeys.onPushToTalkBegan = { [weak self] in
            guard let self else { return }
            if self.pressEndedLockedDictation { self.pressEndedLockedDictation = false; return }
            self.hotkeyFired.send(.pushToTalk)
            self.pendingResumeTask?.cancel()   // a hold is not a tap; never resume under it
            self.pendingResumeTask = nil
            Log.hotkey.info("Yapper key hold -> Voice In")
            self.voiceInput.beginPushToTalk()
        }
        hotkeys.onKeyDown = { [weak self] in
            guard let self else { return }
            // While locked, the next press finishes the dictation, and is nothing else: not a
            // read, not a new hold.
            if self.voiceInput.isLocked {
                self.pressEndedLockedDictation = true
                self.voiceInput.finishLocked()
                return
            }
            self.pressEndedLockedDictation = false
            // A video or song playing: pause it now and open the mic now, instead of waiting
            // out the 0.45 s tap-or-hold decision with the mic shut, which cost the first words.
            // A tap reads aloud, which pauses media anyway; anything else gets it back below.
            // Yapper's own reading still keeps the early mic off: it would hear itself.
            var trim: TimeInterval = 0
            if self.media.isOtherMediaPlaying, self.settings.pauseMediaWhileTalking {
                self.media.pauseIfPlaying()
                trim = Self.mediaPauseLag
            }
            self.voiceInput.keyPressed(playbackActive: self.tts.isPlaying || (trim == 0 && self.media.isOtherMediaPlaying),
                                       trimLead: trim)
        }
        hotkeys.onKeyAbandoned = { [weak self] in
            guard let self else { return }
            self.voiceInput.keyAbandoned()
            // Not a hold after all: media paused at key-down comes back once nobody is talking.
            self.reconsiderMediaResume()
        }
        hotkeys.onLockRequested = { [weak self] in self?.voiceInput.lock() }
        hotkeys.canLockMic = { [weak self] in
            guard let self else { return false }
            return self.voiceInput.state == .listening(.pushToTalk)
        }
        hotkeys.onRepasteLast = { [weak self] in
            Log.hotkey.info("Paste last transcript")
            guard let self else { return }
            guard self.voiceInput.state == .idle, !self.voiceInput.priming else { return }
            guard let text = self.vocabulary.lastTranscript?.delivered, !text.isEmpty else {
                self.lastEvent = "Nothing to paste yet"
                return
            }
            self.toast.paste(text)
        }
        hotkeys.onPushToTalkEnded = { [weak self] in self?.voiceInput.endPushToTalk() }
        hotkeys.onPushToTalkCancelled = { [weak self] in self?.voiceInput.cancelPushToTalk() }
        hotkeys.onDumpAXTree = { [weak self] in
            guard let self else { return }
            self.hotkeyFired.send(.dumpAXTree)
            let front = AccessibilityReader.frontmost()
            let url = AccessibilityReader.saveDumpForFrontmost()
            if let url {
                self.lastEvent = "AX dump → \(url.lastPathComponent)"
                Log.ax.info("Dumped AX for \(front?.bundleID ?? "?", privacy: .public) → \(url.path, privacy: .public)")
            } else {
                self.lastEvent = "AX dump failed"
                Log.ax.error("AX dump failed for \(front?.bundleID ?? "?", privacy: .public)")
            }
        }
        hotkeys.onSkipNext = { [weak self] in
            guard let self else { return }
            self.hotkeyFired.send(.skipNext)
            self.tts.skipToNext()
            self.lastEvent = "Skipped to next"
            Log.hotkey.info("Yapper key+→ -> Skip to next")
        }
    }
}
