import Testing
import Foundation

/// Hands-free turn detection from synthetic RMS levels with an explicit clock.
struct VoiceActivityDetectorTests {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)
    private let step: TimeInterval = 0.085   // one 4096-frame buffer at 48 kHz

    private var config: VoiceActivityDetector.Config {
        var c = VoiceActivityDetector.Config()
        c.silenceTimeout = 1.0
        c.armTimeout = 5
        c.maxUtterance = 20
        return c
    }

    /// Feed `levels` back to back and return every event in order.
    private func run(_ levels: [Float], config: VoiceActivityDetector.Config? = nil) -> [VoiceActivityDetector.Event] {
        var vad = VoiceActivityDetector(config: config ?? self.config, armedAt: t0)
        var events: [VoiceActivityDetector.Event] = []
        for (i, level) in levels.enumerated() {
            if let e = vad.process(level: level, at: t0.addingTimeInterval(Double(i + 1) * step)) { events.append(e) }
        }
        return events
    }

    @Test func silentRoomTimesOutWithoutSpeech() {
        let quiet = [Float](repeating: 0.002, count: 80)   // ~6.8s of nothing
        #expect(run(quiet) == [.timedOut])
    }

    @Test func speechThenSilenceEndsTheTurn() {
        let levels = [Float](repeating: 0.002, count: 6)     // baseline
                   + [Float](repeating: 0.08, count: 12)     // ~1s of talking
                   + [Float](repeating: 0.002, count: 16)    // ~1.4s silence > 1.0 timeout
        #expect(run(levels) == [.speechStarted, .turnEnded])
    }

    @Test func briefBlipDoesNotCountAsOnset() {
        let levels = [Float](repeating: 0.002, count: 6)
                   + [0.09, 0.002, 0.09, 0.002, 0.09, 0.002]   // never 3 loud in a row
                   + [Float](repeating: 0.002, count: 50)
        #expect(run(levels) == [.timedOut])
    }

    @Test func pausesShorterThanTimeoutKeepTheTurnOpen() {
        let levels = [Float](repeating: 0.002, count: 6)
                   + [Float](repeating: 0.08, count: 6)
                   + [Float](repeating: 0.002, count: 6)    // ~0.5s pause
                   + [Float](repeating: 0.08, count: 6)
                   + [Float](repeating: 0.002, count: 16)
        #expect(run(levels) == [.speechStarted, .turnEnded])
    }

    @Test func loudRoomRaisesTheGate() {
        // A constant 0.03 "room" (fan, TV) must not read as speech, but 0.2 over it must.
        let levels = [Float](repeating: 0.03, count: 10)
                   + [Float](repeating: 0.2, count: 6)
                   + [Float](repeating: 0.03, count: 16)
        #expect(run(levels) == [.speechStarted, .turnEnded])
        let onlyRoom = [Float](repeating: 0.03, count: 80)
        #expect(run(onlyRoom) == [.timedOut])
    }

    @Test func maxUtteranceCapsARunawayTurn() {
        var c = config
        c.maxUtterance = 2
        let levels = [Float](repeating: 0.002, count: 6) + [Float](repeating: 0.08, count: 40)
        #expect(run(levels, config: c) == [.speechStarted, .turnEnded])
    }

    @Test func nothingAfterFinish() {
        var vad = VoiceActivityDetector(config: config, armedAt: t0)
        var t = t0
        for _ in 0..<6 { t += step; _ = vad.process(level: 0.002, at: t) }
        for _ in 0..<6 { t += step; _ = vad.process(level: 0.08, at: t) }
        var ended = false
        for _ in 0..<20 { t += step; if vad.process(level: 0.002, at: t) == .turnEnded { ended = true } }
        #expect(ended)
        t += step
        #expect(vad.process(level: 0.5, at: t) == nil)
    }
}
