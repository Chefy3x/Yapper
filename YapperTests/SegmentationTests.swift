import Testing

// segments(from:) decides time-to-first-audio (first sentence alone) and request count
// (the rest batched to ~280 chars). Both properties are load-bearing for the streaming player.
@MainActor
struct SegmentationTests {

    @Test func emptyTextYieldsNoSegments() {
        #expect(SentenceStreamPlayer.segments(from: "").isEmpty)
        #expect(SentenceStreamPlayer.segments(from: "  \n ").isEmpty)
    }

    @Test func singleSentencePassesThrough() {
        #expect(SentenceStreamPlayer.segments(from: "Just one sentence.") == ["Just one sentence."])
    }

    @Test func textWithoutTerminatorsIsOneSegment() {
        #expect(SentenceStreamPlayer.segments(from: "no punctuation at all") == ["no punctuation at all"])
    }

    @Test func firstSentenceIsIsolatedForFastStart() {
        let segments = SentenceStreamPlayer.segments(from: "One. Two. Three.")
        #expect(segments == ["One.", "Two. Three."])
    }

    @Test func remainingSentencesBatchUpToLimit() throws {
        // Five 100-char sentences against the second-batch cap of 350: the first rides alone, the
        // next three batch (299 chars ≤ 350, a fourth would be 399), and the last trails.
        // Capitalized: the .bySentences tokenizer is linguistic and won't split "aaa. aaa." —
        // it needs sentence-like cues such as an uppercase letter after the period.
        let sentence = "A" + String(repeating: "a", count: 98) + "."
        let text = Array(repeating: sentence, count: 5).joined(separator: " ")
        let segments = SentenceStreamPlayer.segments(from: text)
        try #require(segments.count == 3)
        #expect(segments[0] == sentence)
        #expect(segments[1] == Array(repeating: sentence, count: 3).joined(separator: " "))
        #expect(segments[2] == sentence)
    }

    @Test func noContentIsLostAcrossSegmentation() {
        let text = "Alpha beta. Gamma delta. Epsilon zeta. Eta theta."
        let rejoined = SentenceStreamPlayer.segments(from: text).joined(separator: " ")
        #expect(rejoined == text)
    }
}
