import Testing
import Foundation

struct MediaPausePolicyTests {
    private let yapper = "app.yapper.Yapper"

    @Test func pausesOtherPlayingMediaAndResumesIt() {
        var policy = MediaPausePolicy()
        let paused = policy.shouldPause(NowPlaying(bundleID: "com.google.Chrome", playing: true), ownBundleID: yapper)
        #expect(paused)
        let resumed = policy.shouldResume(NowPlaying(bundleID: "com.google.Chrome", playing: false))
        #expect(resumed)
        let again = policy.shouldResume(NowPlaying(bundleID: "com.google.Chrome", playing: false))
        #expect(!again)   // once
    }

    @Test func leavesPausedOrMissingMediaAlone() {
        var policy = MediaPausePolicy()
        let pausedIdle = policy.shouldPause(NowPlaying(bundleID: "com.spotify.client", playing: false), ownBundleID: yapper)
        let pausedNothing = policy.shouldPause(nil, ownBundleID: yapper)
        let resumed = policy.shouldResume(NowPlaying(bundleID: "com.spotify.client", playing: false))
        #expect(!pausedIdle)
        #expect(!pausedNothing)
        #expect(!resumed)
    }

    @Test func neverPausesYapperItself() {
        var policy = MediaPausePolicy()
        let paused = policy.shouldPause(NowPlaying(bundleID: yapper, playing: true), ownBundleID: yapper)
        #expect(!paused)
    }

    @Test func doesNotResumeWhatTheUserAlreadyRestartedOrReplaced() {
        var policy = MediaPausePolicy()
        _ = policy.shouldPause(NowPlaying(bundleID: "com.google.Chrome", playing: true), ownBundleID: yapper)
        let afterUserPlay = policy.shouldResume(NowPlaying(bundleID: "com.google.Chrome", playing: true))
        #expect(!afterUserPlay)

        _ = policy.shouldPause(NowPlaying(bundleID: "com.google.Chrome", playing: true), ownBundleID: yapper)
        let afterSwitch = policy.shouldResume(NowPlaying(bundleID: "com.apple.Music", playing: false))
        #expect(!afterSwitch)
    }
    // MARK: Resume timing

    @Test func holdsWhileAnyoneIsTalking() {
        let gate = MediaResumeGate()
        let now = Date()
        #expect(gate.resumeTime(voiceBusy: true, yapperSpeaking: false, now: now) == nil)
        #expect(gate.resumeTime(voiceBusy: false, yapperSpeaking: true, now: now) == nil)
    }

    @Test func resumesAfterAShortQuietGrace() {
        let gate = MediaResumeGate()
        let now = Date()
        #expect(gate.resumeTime(voiceBusy: false, yapperSpeaking: false, now: now)
                == now.addingTimeInterval(MediaResumeGate.grace))
    }

    @Test func waitsForTheConversationReplyThenGivesUp() {
        let now = Date()
        var gate = MediaResumeGate()
        gate.awaitingReplyUntil = now.addingTimeInterval(MediaResumeGate.replyWait)
        #expect(gate.resumeTime(voiceBusy: false, yapperSpeaking: false, now: now)
                == now.addingTimeInterval(MediaResumeGate.replyWait))
        // Past the deadline it's the normal grace.
        let later = now.addingTimeInterval(MediaResumeGate.replyWait + 1)
        #expect(gate.resumeTime(voiceBusy: false, yapperSpeaking: false, now: later)
                == later.addingTimeInterval(MediaResumeGate.grace))
    }
}
