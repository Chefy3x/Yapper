import Testing
import Foundation

// The transcript is what the liner-notes panel clicks into seeks with, so its lines have to walk
// the same timeline `seek(to:)` walks: contiguous, in order, ending exactly at totalDuration.
// These run on the pre-audio estimates (no network, no synthesis) — the same state the panel is
// in for the first few seconds of every read.
@MainActor
struct TranscriptTests {

    /// Never called: these tests only exercise the pre-audio estimates, which are computed from
    /// character counts before any synthesis is attempted. Failing loudly beats returning silence
    /// if that ever stops being true.
    private struct UnusedSynthesizer: SpeechSynthesizing {
        struct NotExpected: Error {}
        func synthesize(text: String, previousText: String?, nextText: String?,
                        previousRequestIDs: [String]) async throws -> SpeechSegment {
            throw NotExpected()
        }
    }

    private func player(for text: String) -> SentenceStreamPlayer {
        SentenceStreamPlayer(
            sentences: SentenceStreamPlayer.segments(from: text),
            synthesizer: UnusedSynthesizer(),
            cacheURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("yapper-transcript-test-\(UUID().uuidString).mp3"))
    }

    @Test func oneLinePerSentenceInReadingOrder() {
        let p = player(for: "First one. Second one. Third one.")
        #expect(p.transcript.map(\.text) == ["First one.", "Second one.", "Third one."])
    }

    @Test func linesAreContiguousAndSpanTheWholeTimeline() throws {
        let p = player(for: "Alpha beta gamma. Delta epsilon zeta. Eta theta iota. Kappa lambda mu.")
        let lines = p.transcript
        try #require(lines.count == 4)

        #expect(lines[0].start == 0)
        for (a, b) in zip(lines, lines.dropFirst()) {
            #expect(a.end <= b.start + 1e-9)          // never overlap
            #expect(abs(b.start - a.end) < 1e-6)      // never leave a hole
        }
        #expect(abs((lines.last?.end ?? 0) - p.totalDuration) < 1e-6)
    }

    @Test func longerSentencesGetLongerSpans() throws {
        let p = player(for: "Hi. This sentence is considerably longer than the one before it.")
        let lines = p.transcript
        try #require(lines.count == 2)
        #expect((lines[1].end - lines[1].start) > (lines[0].end - lines[0].start))
    }

    @Test func nothingIsLoadedBeforeSynthesisRuns() {
        let p = player(for: "One. Two.")
        #expect(p.transcript.allSatisfy { !$0.isLoaded && !$0.isFailed })
    }

    @Test func emptyTextHasNoTranscript() {
        #expect(player(for: "   \n ").transcript.isEmpty)
    }
}
