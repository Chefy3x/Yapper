import Foundation

/// Decides when a hands-free turn starts and ends from per-buffer RMS levels.
///
/// The room's baseline is learned from the first buffers after the mic opens (the reply has
/// just finished, so the user hasn't started talking yet). Speech onset is a run of buffers
/// well above that baseline; the turn ends after `silenceTimeout` of sub-threshold audio. If
/// nobody speaks within `armTimeout`, the mic closes quietly — no transcription, no event.
struct VoiceActivityDetector {
    enum Event: Equatable { case speechStarted, turnEnded, timedOut }

    struct Config: Sendable {
        /// Absolute RMS floor for speech, so a silent room's tiny fluctuations never trigger.
        var onsetFloor: Float = 0.012
        /// Speech must exceed the learned baseline by this factor.
        var onsetBaselineMultiplier: Float = 2.5
        /// Consecutive loud buffers needed to declare onset (~85 ms each at 4096 @ 48 kHz).
        var onsetBuffers: Int = 3
        /// Once speaking, audio counts as "still talking" above this fraction of the onset gate —
        /// hysteresis so trailing syllables don't end the turn early.
        var continueRatio: Float = 0.5
        /// Silence after speech that ends the turn.
        var silenceTimeout: TimeInterval = 1.8
        /// No speech at all after arming → give up.
        var armTimeout: TimeInterval = 8
        /// Hard ceiling on one utterance.
        var maxUtterance: TimeInterval = 90
        /// Buffers used to learn the room baseline before onset detection is live.
        var baselineBuffers: Int = 4
    }

    let config: Config
    private let armedAt: Date
    private var baseline: Float = 0
    private var baselineCount = 0
    private var loudRun = 0
    private(set) var speechStartedAt: Date?
    private var lastSpeechAt: Date?
    private var finished = false

    init(config: Config = Config(), armedAt: Date = Date()) {
        self.config = config
        self.armedAt = armedAt
    }

    var isSpeaking: Bool { speechStartedAt != nil && !finished }

    private var onsetGate: Float { max(config.onsetFloor, baseline * config.onsetBaselineMultiplier) }

    mutating func process(level: Float, at now: Date = Date()) -> Event? {
        guard !finished else { return nil }

        if speechStartedAt == nil {
            // Learn the room first — those buffers never count toward onset.
            if baselineCount < config.baselineBuffers {
                baseline = (baseline * Float(baselineCount) + level) / Float(baselineCount + 1)
                baselineCount += 1
                return checkArmTimeout(now)
            }
            if level >= onsetGate {
                loudRun += 1
                if loudRun >= config.onsetBuffers {
                    speechStartedAt = now
                    lastSpeechAt = now
                    return .speechStarted
                }
            } else {
                loudRun = 0
                // Keep tracking a slowly drifting room (fan spins up) while nobody talks.
                baseline = baseline * 0.95 + level * 0.05
            }
            return checkArmTimeout(now)
        }

        // Speaking: refresh the silence clock on any buffer above the hysteresis gate.
        if level >= onsetGate * config.continueRatio { lastSpeechAt = now }
        if let started = speechStartedAt, now.timeIntervalSince(started) >= config.maxUtterance {
            finished = true
            return .turnEnded
        }
        if let last = lastSpeechAt, now.timeIntervalSince(last) >= config.silenceTimeout {
            finished = true
            return .turnEnded
        }
        return nil
    }

    private mutating func checkArmTimeout(_ now: Date) -> Event? {
        guard now.timeIntervalSince(armedAt) >= config.armTimeout else { return nil }
        finished = true
        return .timedOut
    }
}
