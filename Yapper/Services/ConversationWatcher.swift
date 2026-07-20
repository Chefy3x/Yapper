import AppKit
import ApplicationServices

/// Watches an allowlist of AI chat apps for newly-completed assistant responses and reports each one
/// exactly once. Detection is clipboard-free (no Copy press) via `AccessibilityReader.probeLatestAssistant`;
/// the heavy copy-press extraction happens in the `onResponseCompleted` handler. Runs only while
/// Conversation Mode is on.
///
/// Completion heuristic per app, per ~0.6s tick:
///   1. the latest assistant turn's text signature is stable across ~1.4s, AND
///   2. an assistant completion control (Copy/feedback) is present, AND
///   3. no "Stop generating" control is present (not still streaming).
/// Browsers are additionally gated on the active tab being an AI site (`aiSiteOK`).
///
/// Timer + state live on the main actor; the AX probes themselves run on `AXWorker` so a slow
/// target app (Chromium rebuilding its AX tree) never hitches the UI. Only one probe pass is in
/// flight at a time — ticks that land during a pass are skipped, which self-throttles when slow.
@MainActor
final class ConversationWatcher {

    struct PendingResponse {
        let bundleID: String
        let sourceApp: String
        let pid: pid_t
        let copyButton: AXUIElement
        let signature: String
    }

    /// Fired once when a new assistant response has finished. The handler runs the heavy extraction.
    var onResponseCompleted: ((PendingResponse) -> Void)?

    private let settings: SettingsStore
    private var timer: Timer?
    private var perApp: [pid_t: WatchedApp] = [:]
    /// True while a probe pass (baseline or tick) is on AXWorker; ticks skip until it lands.
    private var probeInFlight = false
    /// Bumped on every start/stop so a pass that was in flight across a restart discards itself.
    private var generation = 0

    private static let tickInterval: TimeInterval = 0.6
    /// How long the latest turn's text must stay unchanged to count as complete.
    /// Injectable so tests don't have to wait out the real 1.4s.
    private let stabilityWindow: TimeInterval
    /// How many times a response's copy-press extraction may fail before we stop retrying it.
    private static let maxExtractionAttempts = 3

    init(settings: SettingsStore, stabilityWindow: TimeInterval = 1.4) {
        self.settings = settings
        self.stabilityWindow = stabilityWindow
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        generation += 1
        perApp = [:]
        baselineAllApps()
        let t = Timer(timeInterval: Self.tickInterval, target: self,
                      selector: #selector(handleTick), userInfo: nil, repeats: true)
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)   // keep ticking during menu tracking
        timer = t
        Log.app.info("ConversationWatcher started")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        generation += 1        // any in-flight pass sees a stale generation and drops its results
        probeInFlight = false
        perApp = [:]
        Log.app.info("ConversationWatcher stopped")
    }

    @objc private func handleTick() { tick() }

    // MARK: - Per-app state

    private struct WatchedApp {
        var lastSpokenSignature: String?
        var candidateSignature: String?
        var candidateFirstSeen: Date?
        var failedSignature: String?
        var failedAttempts: Int = 0
    }

    struct RunningApp { let pid: pid_t; let bundleID: String; let name: String }   // internal for tests

    private func runningAllowlistedApps() -> [RunningApp] {
        let allow = Set(settings.conversationAllowlist)
        guard !allow.isEmpty else { return [] }
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bid = app.bundleIdentifier, allow.contains(bid) else { return nil }
            return RunningApp(pid: app.processIdentifier, bundleID: bid, name: app.localizedName ?? bid)
        }
    }

    /// Record each app's current latest turn as already-spoken so a response already on screen when
    /// Conversation Mode is switched ON is not auto-read. Runs as an async probe pass on AXWorker;
    /// ticks are skipped (`probeInFlight`) until the baseline lands.
    private func baselineAllApps() {
        let apps = runningAllowlistedApps()
        guard !apps.isEmpty else { return }
        probeInFlight = true
        let gen = generation
        Task { [weak self] in
            var seeds: [(pid: pid_t, text: String)] = []
            for app in apps {
                if let p = await AccessibilityReader.probeLatestAssistant(pid: app.pid, bundleID: app.bundleID),
                   p.hasCompletionControl {
                    seeds.append((pid: app.pid, text: p.visibleText))
                }
            }
            self?.applyBaseline(seeds, generation: gen)
        }
    }

    private func applyBaseline(_ seeds: [(pid: pid_t, text: String)], generation gen: Int) {
        guard gen == generation else { return }   // superseded by a stop()/start()
        probeInFlight = false
        guard isRunning else { return }
        for seed in seeds {
            perApp[seed.pid] = WatchedApp(lastSpokenSignature: signature(seed.text))
        }
    }

    // MARK: - Detection

    private func tick() {
        // Skip if the previous pass is still probing — self-throttles when a watched app is slow.
        guard !probeInFlight else { return }
        let apps = runningAllowlistedApps()
        let livePids = Set(apps.map { $0.pid })
        perApp = perApp.filter { livePids.contains($0.key) }   // drop apps that quit
        guard !apps.isEmpty else { return }

        probeInFlight = true
        let gen = generation
        Task { [weak self] in
            var probes: [(app: RunningApp, probe: AccessibilityReader.ProbeResult)] = []
            for app in apps {
                if let p = await AccessibilityReader.probeLatestAssistant(pid: app.pid, bundleID: app.bundleID) {
                    probes.append((app: app, probe: p))
                }
            }
            self?.apply(probes: probes, generation: gen)
        }
    }

    private func apply(probes: [(app: RunningApp, probe: AccessibilityReader.ProbeResult)], generation gen: Int) {
        guard gen == generation else { return }   // superseded by a stop()/start()
        probeInFlight = false
        guard isRunning else { return }
        for (app, probe) in probes { evaluate(app: app, probe: probe) }
    }

    /// One detection step for one app. Internal so tests can drive the state machine directly
    /// with synthetic probes — no timer, no AX.
    func evaluate(app: RunningApp, probe p: AccessibilityReader.ProbeResult) {
        var state = perApp[app.pid] ?? WatchedApp()
        defer { perApp[app.pid] = state }

        // Browser tab gate: only read when the active tab is an AI site.
        if !p.aiSiteOK { state.candidateSignature = nil; return }
        // Still streaming → reset any candidate and wait.
        if p.hasStopControl { state.candidateSignature = nil; return }
        // Need a completion control + a button to extract from.
        guard p.hasCompletionControl, let copyButton = p.copyButton else { return }

        let sig = signature(p.visibleText)
        if sig.isEmpty || sig == state.lastSpokenSignature { return }   // empty / dedup / baselined

        if sig != state.candidateSignature {
            // New candidate; start the stability clock.
            state.candidateSignature = sig
            state.candidateFirstSeen = Date()
            return
        }
        // Same candidate as last tick — has it been stable long enough?
        guard let since = state.candidateFirstSeen,
              Date().timeIntervalSince(since) >= stabilityWindow else { return }

        // CONFIRMED COMPLETE — mark spoken BEFORE firing so a re-detect can't double-fire.
        state.lastSpokenSignature = sig
        state.candidateSignature = nil
        state.candidateFirstSeen = nil
        Log.ax.info("Conversation: completed response detected in \(app.name, privacy: .public)")
        onResponseCompleted?(PendingResponse(bundleID: app.bundleID, sourceApp: app.name,
                                             pid: app.pid, copyButton: copyButton, signature: sig))
    }

    // MARK: - Extraction retry

    /// Called when the heavy copy-press extraction failed — most often because the probed
    /// AXUIElement went stale after the app re-rendered. Un-marks the response so a future tick
    /// re-detects it (with a freshly-probed button) and fires again after the stability window.
    /// Gives up after `maxExtractionAttempts` so a permanently broken control can't loop forever.
    func retryFailedExtraction(_ pending: PendingResponse) {
        guard isRunning,
              var state = perApp[pending.pid],
              state.lastSpokenSignature == pending.signature else { return }

        if state.failedSignature == pending.signature {
            state.failedAttempts += 1
        } else {
            state.failedSignature = pending.signature
            state.failedAttempts = 1
        }

        if state.failedAttempts < Self.maxExtractionAttempts {
            state.lastSpokenSignature = nil   // re-detect on a future tick
            Log.ax.info("Conversation: extraction failed (attempt \(state.failedAttempts)) in \(pending.sourceApp, privacy: .public); will retry")
        } else {
            Log.ax.error("Conversation: extraction failed \(state.failedAttempts) times in \(pending.sourceApp, privacy: .public); giving up on this response")
        }
        perApp[pending.pid] = state
    }

    /// Cheap fingerprint that changes on every streamed token (length + head + tail), so stability
    /// detection works and identical turns dedup. Empty text maps to "" — NOT "0||" — so the
    /// `sig.isEmpty` guard in evaluate actually rejects blank probes instead of firing on them.
    private func signature(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return "\(trimmed.count)|\(trimmed.prefix(120))|\(trimmed.suffix(120))"
    }
}
