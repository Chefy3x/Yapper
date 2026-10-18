import Foundation

/// What macOS's Now Playing says, reduced to what pausing needs.
struct NowPlaying: Equatable, Sendable {
    var bundleID: String?
    var playing: Bool
}

/// Decides when to pause and when to resume. Pure, so the rules are tested without media.
///
/// Yapper resumes only what it paused itself, and only if it is still paused: if the user
/// pressed play during the turn, or something else took over Now Playing, hands off.
struct MediaPausePolicy: Sendable {
    private(set) var pausedBundleID: String?

    mutating func shouldPause(_ now: NowPlaying?, ownBundleID: String?) -> Bool {
        guard pausedBundleID == nil, let now, now.playing, now.bundleID != ownBundleID else { return false }
        pausedBundleID = now.bundleID ?? ""
        return true
    }

    mutating func shouldResume(_ now: NowPlaying?) -> Bool {
        guard let paused = pausedBundleID else { return false }
        pausedBundleID = nil
        guard let now, !now.playing else { return false }
        return (now.bundleID ?? "") == paused
    }
}

/// When Yapper may hand paused media back. Pure, so the timing rules are tested directly.
///
/// The media stays paused while anyone is talking: the user (a talk-key turn, or the hands-free
/// mic waiting for them) or Yapper (reading, or replies queued). In Conversation Mode a delivered
/// dictation is usually answered and read aloud, so the pause also waits for that reply rather
/// than letting the video play for a few seconds and stop again.
struct MediaResumeGate: Sendable {
    /// Quiet this long before resuming, so the gap between two queued replies isn't a resume.
    static let grace: TimeInterval = 1.5
    /// How long a Conversation Mode dictation keeps the media paused while waiting for the reply.
    static let replyWait: TimeInterval = 60

    var awaitingReplyUntil: Date?

    /// When to resume if nothing changes; nil while someone is talking.
    func resumeTime(voiceBusy: Bool, yapperSpeaking: Bool, now: Date) -> Date? {
        if voiceBusy || yapperSpeaking { return nil }
        if let until = awaitingReplyUntil, until > now { return until }
        return now.addingTimeInterval(Self.grace)
    }
}

/// Pauses whatever else is playing — a YouTube tab, Spotify, a podcast — while the user talks,
/// and plays it again afterwards. A five-minute thought shouldn't compete with a video, and the
/// mic shouldn't transcribe it.
///
/// Since macOS 15.4 only Apple-signed processes may use MediaRemote, so Yapper goes through the
/// vendored mediaremote-adapter: `/usr/bin/perl` (Apple-signed) loads its framework and streams
/// Now Playing as JSON lines, or sends one command. If the helper can't run, nothing is paused
/// and nothing else breaks.
@MainActor
final class MediaController {
    private enum Command: Int { case play = 0, pause = 1 }

    private(set) var nowPlaying: NowPlaying?
    private var policy = MediaPausePolicy()
    private var stream: Process?
    private var lineBuffer = Data()
    private var stopping = false
    private var restarts = 0
    private let ownBundleID = Bundle.main.bundleIdentifier

    /// Yapper paused something and hasn't given it back yet.
    var isHoldingPause: Bool { policy.pausedBundleID != nil }

    /// Something other than Yapper is audibly playing right now.
    var isOtherMediaPlaying: Bool {
        guard let nowPlaying, nowPlaying.playing else { return false }
        return nowPlaying.bundleID != ownBundleID
    }

    private static let perl = URL(fileURLWithPath: "/usr/bin/perl")

    private var adapter: (script: URL, framework: URL)? {
        guard let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let frameworks = Bundle.main.privateFrameworksURL else { return nil }
        let framework = frameworks.appendingPathComponent("MediaRemoteAdapter.framework")
        guard FileManager.default.fileExists(atPath: framework.path) else { return nil }
        return (script, framework)
    }

    // MARK: Lifecycle

    func start() {
        guard stream == nil else { return }
        guard let adapter else {
            Log.app.notice("Media pause unavailable: adapter not bundled")
            return
        }
        stopping = false
        let process = Process()
        process.executableURL = Self.perl
        process.arguments = [adapter.script.path, adapter.framework.path, "stream", "--no-diff", "--debounce=100"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            Task { @MainActor [weak self] in self?.ingest(chunk) }
        }
        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor [weak self] in self?.streamEnded(status: status) }
        }
        do {
            try process.run()
            stream = process
        } catch {
            Log.app.error("Media stream failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        stopping = true
        stream?.terminate()
        stream = nil
    }

    private func streamEnded(status: Int32) {
        stream = nil
        nowPlaying = nil
        guard !stopping else { return }
        // A helper that keeps dying (MediaRemote access withdrawn) stops being retried.
        guard restarts < 5 else {
            Log.app.notice("Media stream gave up after repeated exits (last status \(status, privacy: .public))")
            return
        }
        restarts += 1
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.start()
        }
    }

    private func ingest(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lineBuffer.append(chunk)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer[lineBuffer.startIndex..<newline]
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "data",
                  let payload = object["payload"] as? [String: Any] else { continue }
            if payload.isEmpty {
                nowPlaying = nil
            } else {
                nowPlaying = NowPlaying(bundleID: payload["bundleIdentifier"] as? String,
                                        playing: payload["playing"] as? Bool ?? false)
            }
            restarts = 0
        }
    }

    // MARK: Pause / resume

    /// Someone started talking: the user, or Yapper reading.
    func pauseIfPlaying() {
        guard policy.shouldPause(nowPlaying, ownBundleID: ownBundleID) else { return }
        Log.app.info("Pausing \(self.nowPlaying?.bundleID ?? "?", privacy: .public) while the user talks")
        send(.pause)
    }

    /// Everyone is done talking (see `MediaResumeGate`).
    func resumeIfPaused() {
        guard policy.shouldResume(nowPlaying) else { return }
        Log.app.info("Resuming \(self.nowPlaying?.bundleID ?? "?", privacy: .public)")
        send(.play)
    }

    private func send(_ command: Command) {
        guard let adapter else { return }
        let process = Process()
        process.executableURL = Self.perl
        process.arguments = [adapter.script.path, adapter.framework.path, "send", String(command.rawValue)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            Log.app.error("Media \(String(describing: command), privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
