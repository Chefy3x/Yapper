import AVFoundation
import Combine

/// Plays a piece of text as a sequence of segments: the first sentence alone, then progressively
/// larger batches. The first segment starts playing as soon as it's synthesized, while the rest are
/// fetched in the background — so time-to-first-audio is ~one short sentence instead of the whole
/// response. Each request is stitched to the previous ones' audio (`previous_request_ids`), so the
/// delivery flows like a single take rather than independently-voiced lines.
///
/// Each segment is decoded into its own `AVAudioPlayer` (from in-memory `Data`, no temp files) and
/// played back-to-back; the seams land on natural sentence pauses. All segment audio is appended,
/// in order, into a single cache file so History replay reuses one continuous clip.
///
/// Exposes the same surface the mini player binds to (`state`, `currentTime`, `totalDuration`,
/// `rate`, pause/resume/seek/setRate) as the old single-file streamer.
@MainActor
final class SentenceStreamPlayer: NSObject, ObservableObject {

    enum State: Equatable {
        case idle
        case bufferingFirstAudio
        case playing
        case paused
        case finished
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var totalDuration: TimeInterval = 0
    @Published private(set) var rate: Float = 1.0
    /// Stretches of the timeline whose audio is already synthesized — a scrub landing inside
    /// one plays instantly; outside, playback buffers until that segment is generated. Measured
    /// on the same scale as `totalDuration`/`seek(to:)` (real durations where known, estimates
    /// otherwise), so the deck can draw them on its ruler and they line up with where scrubs land.
    @Published private(set) var bufferedRanges: [ClosedRange<TimeInterval>] = []
    /// The read-along transcript: one line per sentence, each carrying the stretch of timeline it
    /// occupies. Built on the same walk as `seek(to:)`, so clicking a line lands exactly where the
    /// scrubber would. Timings inside a segment are apportioned by character count — the API gives
    /// no word alignment, so a line is accurate to its segment and approximate within it.
    @Published private(set) var transcript: [TranscriptLine] = []

    /// One clickable line of the transcript.
    struct TranscriptLine: Identifiable, Equatable {
        let id: Int
        let text: String
        let start: TimeInterval
        let end: TimeInterval
        /// This line's audio exists — clicking it plays instantly. Otherwise the deck parks there
        /// and the pipeline synthesizes it next.
        let isLoaded: Bool
        /// Its segment failed to synthesize; it will never be spoken.
        let isFailed: Bool

        func contains(_ t: TimeInterval) -> Bool { t >= start && t < end }
    }

    static let availableRates: [Float] = [1.0, 1.25, 1.5, 1.75, 2.0]

    let cacheURL: URL
    var onFinish: (() -> Void)?
    /// Called when no audio could be produced at all (e.g. the first segment failed to synthesize),
    /// so the coordinator can fall back to the native voice.
    var onFailure: (() -> Void)?

    // MARK: - Segments

    private struct Segment {
        let text: String
        var data: Data?
        var duration: TimeInterval?
        var failed = false
        /// The API's `request-id` for this segment's audio — lets a later segment stitch to it
        /// even when synthesis ran out of order after a scrub jump.
        var requestID: String? = nil
    }

    private var segments: [Segment]
    private var players: [Int: AVAudioPlayer] = [:]
    private var currentIndex = 0
    private var baseTime: TimeInterval = 0        // summed duration of segments before currentIndex
    /// Set when a forward scrub parks on a segment whose audio hasn't been synthesized yet: the
    /// intra-segment offset to enter at once that segment lands. Consumed by playCurrent()/resume().
    private var pendingSeekOffset: TimeInterval? = nil

    private let voiceID: String
    private let modelID: String
    private let outputFormat: String
    private let voiceSettings: ElevenLabsClient.VoiceSettings
    private let apiKey: String
    private let isReplay: Bool

    private let delegateProxy = SegPlayerDelegate()
    private var tick: Timer?
    /// The cache is assembled here (in segment order, from the in-memory datas) once the pipeline
    /// has synthesized EVERY segment, then renamed to `cacheURL` — so History can never resolve a
    /// half-written or out-of-order clip.
    private var partURL: URL?
    private var synthTask: Task<Void, Never>?

    /// Rough chars→seconds factor for estimating total duration before real durations are known.
    private static let secondsPerChar: TimeInterval = 0.060

    // MARK: - Init

    /// Live synthesis init.
    init(sentences: [String], voiceID: String, modelID: String, outputFormat: String,
         voiceSettings: ElevenLabsClient.VoiceSettings, apiKey: String, cacheURL: URL) {
        self.segments = sentences.map { Segment(text: $0) }
        self.voiceID = voiceID
        self.modelID = modelID
        self.outputFormat = outputFormat
        self.voiceSettings = voiceSettings
        self.apiKey = apiKey
        self.cacheURL = cacheURL
        self.isReplay = false
        super.init()
        configureDelegate()
        prepareCacheFile()
        let chars = sentences.reduce(0) { $0 + $1.count }
        totalDuration = max(0.1, Double(chars) * Self.secondsPerChar)
        recomputeTranscript(perChar: Self.secondsPerChar)   // readable before the first audio lands
    }

    /// Replay init — a single, already-complete MP3 on disk. No synthesis. `text` is the read's
    /// original text: it never affects playback, it just gives the transcript something to show
    /// (spread across the clip's real duration by character count).
    init(existingFile: URL, text: String = "") {
        let data = try? Data(contentsOf: existingFile)
        self.segments = [Segment(text: text, data: data)]
        self.voiceID = ""; self.modelID = ""; self.outputFormat = ""; self.apiKey = ""
        self.voiceSettings = .natural
        self.cacheURL = existingFile
        self.isReplay = true
        super.init()
        configureDelegate()
    }

    private func configureDelegate() {
        delegateProxy.onFinish = { [weak self] finished in
            Task { @MainActor in self?.handleSegmentFinished(finished) }
        }
    }

    // MARK: - Control

    func start() {
        state = .bufferingFirstAudio
        if !isReplay { launchSynthPipeline() }
        playCurrent()   // replay: starts now; live: stays buffering until segment 0 lands
    }

    func pause() {
        guard let p = players[currentIndex], p.isPlaying else { return }
        p.pause()
        state = .paused
        stopTick()
    }

    func resume() {
        guard currentIndex < segments.count else { return }
        if players[currentIndex] == nil { makePlayer(for: currentIndex) }
        guard let p = players[currentIndex] else { state = .bufferingFirstAudio; return }
        // A forward scrub may have parked us mid-segment before its audio existed — start there.
        if let off = pendingSeekOffset {
            p.currentTime = min(max(0, off), p.duration)
            pendingSeekOffset = nil
        }
        if p.play() {
            p.rate = rate
            state = .playing
            startTick()
        }
    }

    func stop() {
        synthTask?.cancel()
        synthTask = nil
        players.values.forEach { $0.stop() }
        players.removeAll()
        stopTick()
        pendingSeekOffset = nil
        discardPartFile()   // interrupted synthesis — never publish a truncated clip
        state = .idle
    }

    func setRate(_ newRate: Float) {
        let clamped = min(max(newRate, Self.availableRates.first ?? 1.0), Self.availableRates.last ?? 2.0)
        rate = clamped
        if let p = players[currentIndex] {
            p.enableRate = true
            p.rate = clamped
        }
    }

    func cycleRate() {
        let rates = Self.availableRates
        let idx = rates.firstIndex(of: rate) ?? 0
        setRate(rates[(idx + 1) % rates.count])
    }

    /// Step to the adjacent rate (clamped at the ends) — the deck's REW/FF speed controls.
    func stepRate(up: Bool) {
        let rates = Self.availableRates
        let idx = rates.firstIndex(of: rate)
            ?? rates.enumerated().min(by: { abs($0.1 - rate) < abs($1.1 - rate) })!.offset
        let next = up ? min(idx + 1, rates.count - 1) : max(idx - 1, 0)
        setRate(rates[next])
    }

    func seek(to seconds: TimeInterval) {
        let target = max(0, min(seconds, totalDuration))
        // Same estimate recomputeTotalDuration uses, so the scrubber maps onto the same scale.
        let perChar = measuredSecondsPerChar
        var acc: TimeInterval = 0
        for i in 0..<segments.count {
            // Failed segments are zero-length: recomputeTotalDuration excludes them from the
            // scrubber's scale, and landing on one would park forever (no audio is coming).
            let d = segments[i].failed ? 0
                : segments[i].duration ?? Double(segments[i].text.count) * perChar
            let isLast = (i == segments.count - 1)
            if target < acc + d || isLast {
                // Whether audio was being produced before the scrub — decides if playback should
                // resume automatically once the target segment lands.
                let wasActive = (state == .playing || state == .bufferingFirstAudio)
                if currentIndex != i { players[currentIndex]?.stop() }
                currentIndex = i
                baseTime = acc
                let offset = max(0, target - acc)

                if players[i] == nil { makePlayer(for: i) }
                guard let p = players[i] else {
                    // Scrubbing ahead of the synthesized buffer: the target segment's audio doesn't
                    // exist yet. Park the transport on it and hold the needle where the user dropped
                    // it — the pipeline synthesizes this segment NEXT (see nextSynthIndex) and its
                    // landing callback resumes playback here; a manual resume honors the same
                    // pending offset.
                    Log.tts.log("Seek \(seconds, format: .fixed(precision: 1))s → parked on unsynthesized segment \(i), waiting for audio")
                    currentTime = target
                    pendingSeekOffset = offset
                    stopTick()
                    state = wasActive ? .bufferingFirstAudio : .paused
                    return
                }
                pendingSeekOffset = nil
                let clamped = min(offset, p.duration)
                p.currentTime = clamped
                currentTime = baseTime + clamped
                Log.tts.log("Seek \(seconds, format: .fixed(precision: 1))s → segment \(i) at \(clamped, format: .fixed(precision: 1))s (\(wasActive ? "playing" : "holding", privacy: .public))")
                if wasActive, p.play() {
                    p.rate = rate
                    state = .playing
                    startTick()
                }
                return
            }
            acc += d
        }
    }

    // MARK: - Synthesis pipeline

    /// The next segment the pipeline should synthesize, re-decided after every request so a scrub
    /// can redirect it mid-read:
    /// 1. whatever the playhead is sitting on (a scrub parked there, or playback caught up),
    ///    then onward from the playhead — audio the user is about to hear always wins,
    /// 2. else the earliest gap left behind by forward jumps — playback never revisits it, but
    ///    the History cache needs every segment.
    /// Before scrubs could jump the playhead, this was a plain 0..<count walk; sequential order
    /// made forward scrubs wait for every intervening segment on the slow models.
    private func nextSynthIndex() -> Int? {
        let needs: (Segment) -> Bool = { $0.data == nil && !$0.failed }
        let head = min(currentIndex, segments.count)
        if let ahead = (head..<segments.count).first(where: { needs(segments[$0]) }) { return ahead }
        return (0..<head).first(where: { needs(segments[$0]) })
    }

    /// Ids of the contiguous already-synthesized run ending just before `i` (oldest → newest,
    /// capped at the API's limit of 3). Stitching survives out-of-order synthesis: a segment
    /// stitches to its real predecessors when their audio exists, and falls back to
    /// `previousText` conditioning when the user jumped into unsynthesized territory.
    private func stitchIDs(before i: Int) -> [String] {
        var ids: [String] = []
        var j = i - 1
        while j >= 0, ids.count < 3, segments[j].data != nil, let id = segments[j].requestID {
            ids.append(id)
            j -= 1
        }
        return ids.reversed()
    }

    private func launchSynthPipeline() {
        synthTask = Task { [weak self] in
            guard let self else { return }
            // `self` is held strongly from here on purpose: the pipeline keeps filling gaps (and
            // finally publishes the cache) even after playback finished and the UI let go.
            while !Task.isCancelled {
                guard let i = self.nextSynthIndex() else { break }
                let req = ElevenLabsClient.Request(
                    voiceID: self.voiceID,
                    text: self.segments[i].text,
                    modelID: self.modelID,
                    outputFormat: self.outputFormat,
                    voiceSettings: self.voiceSettings,
                    // Text conditioning: `nextText` always (that audio doesn't exist yet);
                    // `previousText` is the fallback the API uses when no request ids are sent
                    // (first segment, or a jump landing). Only `text` is voiced.
                    previousText: i > 0 ? self.segments[i - 1].text : nil,
                    nextText: i + 1 < self.segments.count ? self.segments[i + 1].text : nil,
                    previousRequestIDs: self.stitchIDs(before: i)
                )
                do {
                    let result = try await ElevenLabsClient.synthesize(req, apiKey: self.apiKey)
                    if Task.isCancelled { return }
                    self.segments[i].requestID = result.requestID
                    self.segments[i].data = result.data
                    self.makePlayer(for: i)
                    // If playback is waiting on this segment (first audio, or a parked scrub),
                    // kick it off.
                    if i == self.currentIndex,
                       self.state == .bufferingFirstAudio {
                        self.playCurrent()
                    }
                } catch {
                    // A stop() cancels the in-flight request; that's teardown, not a synth failure.
                    if Task.isCancelled { return }
                    Log.tts.error("Segment \(i) synth failed: \(error.localizedDescription, privacy: .public)")
                    self.segments[i].failed = true
                    self.recomputeTotalDuration()   // drops the failed estimate from the scrubber scale
                    // Nothing has played yet and the segment we're waiting on failed → give up to native.
                    if i == self.currentIndex, self.players.isEmpty {
                        self.state = .failed(error.localizedDescription)
                        self.stopTick()
                        self.discardPartFile()
                        self.onFailure?()
                        return
                    }
                    // Mid-stream failure: if we're stalled waiting on it, advance past it.
                    if i == self.currentIndex { self.advance() }
                }
            }
            self.publishCacheIfComplete()
        }
    }

    // MARK: - Playback helpers

    private func makePlayer(for i: Int) {
        guard players[i] == nil, let data = segments[i].data else { return }
        do {
            let p = try AVAudioPlayer(data: data)
            p.delegate = delegateProxy
            p.enableRate = true
            p.prepareToPlay()
            p.rate = rate
            players[i] = p
            segments[i].duration = p.duration
            recomputeTotalDuration()
        } catch {
            segments[i].failed = true
            recomputeTotalDuration()
        }
    }

    private func playCurrent() {
        guard currentIndex < segments.count else { finishAll(); return }
        if segments[currentIndex].failed { advance(); return }
        if players[currentIndex] == nil { makePlayer(for: currentIndex) }
        guard let p = players[currentIndex] else {
            // Data not ready yet — stay buffering; the pipeline will call us back.
            if state != .paused { state = .bufferingFirstAudio }
            return
        }
        // Normally enter a segment from its top: a player stopped mid-segment by a seek-away
        // keeps its old position (AVAudioPlayer.stop() does not rewind), and play() would
        // resume there — audibly skipping the start of the segment after a rewind. The one
        // exception is a forward scrub that parked here before the audio existed: enter at that
        // pending intra-segment offset instead of restarting from 0.
        let startAt = pendingSeekOffset ?? 0
        pendingSeekOffset = nil
        p.currentTime = min(max(0, startAt), p.duration)
        if p.play() {
            p.rate = rate
            state = .playing
            startTick()
        } else {
            state = .failed("AVAudioPlayer.play() returned false")
        }
    }

    private func handleSegmentFinished(_ finished: AVAudioPlayer) {
        // Only react to the segment that's actually current finishing naturally.
        guard players[currentIndex] === finished else { return }
        advance()
    }

    private func advance() {
        baseTime += segments[currentIndex].duration ?? 0
        currentIndex += 1
        if currentIndex >= segments.count {
            finishAll()
            return
        }
        playCurrent()
    }

    private func finishAll() {
        stopTick()
        currentTime = totalDuration
        state = .finished
        onFinish?()
        // Cache publishing happens when the PIPELINE drains (publishCacheIfComplete), not here —
        // after a forward scrub, playback can finish while skipped segments are still backfilling.
    }

    /// Chars→seconds rate observed from the segments that already have real audio; falls back to
    /// the rough constant until the first segment lands. Using the voice's *measured* pace makes
    /// the estimated total converge on the true duration early instead of jumping at the end.
    private var measuredSecondsPerChar: TimeInterval {
        var seconds: TimeInterval = 0
        var chars = 0
        for seg in segments where seg.duration != nil && !seg.text.isEmpty {
            seconds += seg.duration ?? 0
            chars += seg.text.count
        }
        guard chars > 0, seconds > 0 else { return Self.secondsPerChar }
        return seconds / Double(chars)
    }

    private func recomputeTotalDuration() {
        let perChar = measuredSecondsPerChar
        var sum: TimeInterval = 0
        for seg in segments {
            if let d = seg.duration { sum += d }
            else if !seg.failed { sum += Double(seg.text.count) * perChar }
        }
        totalDuration = max(0.1, sum)
        recomputeBufferedRanges(perChar: perChar)
        recomputeTranscript(perChar: perChar)
    }

    /// Rebuild the transcript on the same walk `seek(to:)` uses, so a line's `start` is exactly
    /// the time that seeks into it. Each segment's span is divided among its sentences by
    /// character count; the last sentence absorbs the rounding so lines stay contiguous.
    private func recomputeTranscript(perChar: TimeInterval) {
        var lines: [TranscriptLine] = []
        var acc: TimeInterval = 0
        for seg in segments {
            let span = seg.failed ? 0 : (seg.duration ?? Double(seg.text.count) * perChar)
            let sentences = Self.sentences(in: seg.text)
            let chars = max(1, sentences.reduce(0) { $0 + $1.count })
            var offset: TimeInterval = 0
            for (k, s) in sentences.enumerated() {
                let isLast = (k == sentences.count - 1)
                let start = acc + offset
                offset += span * Double(s.count) / Double(chars)
                lines.append(TranscriptLine(id: lines.count, text: s,
                                            start: start,
                                            end: isLast ? acc + span : max(acc + offset, start),
                                            isLoaded: seg.data != nil,
                                            isFailed: seg.failed))
            }
            acc += span
        }
        transcript = lines
    }

    /// Merge the synthesized segments into contiguous timeline ranges, on the same walk
    /// `seek(to:)` uses. Failed segments are zero-length there, so they can't split a run.
    private func recomputeBufferedRanges(perChar: TimeInterval) {
        var ranges: [ClosedRange<TimeInterval>] = []
        var acc: TimeInterval = 0
        var runStart: TimeInterval? = nil
        for seg in segments {
            let d = seg.failed ? 0 : (seg.duration ?? Double(seg.text.count) * perChar)
            let buffered = seg.data != nil || seg.failed
            if buffered, runStart == nil { runStart = acc }
            if !buffered, let start = runStart {
                if acc > start { ranges.append(start...acc) }
                runStart = nil
            }
            acc += d
        }
        if let start = runStart, acc > start { ranges.append(start...acc) }
        bufferedRanges = ranges
    }

    // MARK: - Cache file

    private func prepareCacheFile() {
        let fm = FileManager.default
        try? fm.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        partURL = cacheURL.appendingPathExtension("part")
    }

    /// Runs when the synth pipeline drains. Publishes the cache only if every segment's audio
    /// made it in — a clip with silent holes (mid-stream synth failure) is worse than
    /// re-synthesizing on replay. Written from the in-memory datas in segment order, so the
    /// file is correct even when scrub jumps made synthesis run out of order.
    private func publishCacheIfComplete() {
        guard !isReplay, let partURL else { return }
        guard segments.allSatisfy({ $0.data != nil }) else {
            discardPartFile()
            return
        }
        let whole = segments.compactMap(\.data).reduce(into: Data()) { $0.append($1) }
        do {
            try whole.write(to: partURL)
            try FileManager.default.moveItem(at: partURL, to: cacheURL)
            self.partURL = nil
        } catch {
            Log.tts.error("Cache publish failed: \(error.localizedDescription, privacy: .public)")
            discardPartFile()
        }
    }

    /// Delete the in-progress temp file (stop, or synthesis gave up).
    private func discardPartFile() {
        if let partURL { try? FileManager.default.removeItem(at: partURL) }
        partURL = nil
    }

    // MARK: - Tick

    private func startTick() {
        stopTick()
        tick = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.players[self.currentIndex] else { return }
                self.currentTime = self.baseTime + p.currentTime
            }
        }
    }

    private func stopTick() {
        tick?.invalidate()
        tick = nil
    }

    // MARK: - Sentence segmentation

    /// Batch caps by position: the first sentence rides alone (fast time-to-first-audio), the
    /// second batch stays small so it's synthesized before that short opener finishes playing,
    /// and everything after ships in big batches — the model gets paragraph-scale context and
    /// audible seams become rare.
    private static let secondBatchCap = 350
    private static let batchCap = 1_000

    /// Split text into playback segments: the first sentence alone (for a fast start), then
    /// progressively larger sentence batches (see the caps above). Fewer, bigger requests plus
    /// request stitching keep the read sounding like one take instead of stitched-together lines.
    static func segments(from text: String) -> [String] {
        let sentences = Self.sentences(in: text)
        guard let first = sentences.first else { return [] }

        var result: [String] = [first]
        var buffer = ""
        for s in sentences.dropFirst() {
            let cap = result.count == 1 ? Self.secondBatchCap : Self.batchCap
            if buffer.isEmpty {
                buffer = s
            } else if buffer.count + s.count + 1 <= cap {
                buffer += " " + s
            } else {
                result.append(buffer)
                buffer = s
            }
        }
        if !buffer.isEmpty { result.append(buffer) }
        return result
    }

    /// Sentence split shared by segmentation and the transcript, so every transcript line is a
    /// whole sentence of exactly the text that was sent for synthesis. Empty in, empty out —
    /// a replay with no stored text simply has no transcript.
    static func sentences(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var out: [String] = []
        trimmed.enumerateSubstrings(in: trimmed.startIndex..., options: .bySentences) { sub, _, _, _ in
            if let s = sub?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                out.append(s)
            }
        }
        return out.isEmpty ? [trimmed] : out
    }

    // MARK: - Delegate proxy

    private final class SegPlayerDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
        var onFinish: ((AVAudioPlayer) -> Void)?
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            onFinish?(player)
        }
    }
}
