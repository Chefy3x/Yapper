import Testing

struct TranscriptFilterTests {
    private func seg(_ text: String, logprob: Float = -0.3, noSpeech: Float = 0.05, compression: Float = 1.3) -> TranscriptSegment {
        TranscriptSegment(text: text, avgLogprob: logprob, noSpeechProb: noSpeech, compressionRatio: compression)
    }

    @Test func stripsWhisperSpecialTokens() {
        let raw = "<|startoftranscript|><|en|><|transcribe|><|0.00|> Hello there,<|1.20|><|1.40|> how are you?<|2.80|><|endoftext|>"
        #expect(TranscriptFilter.stripSpecialTokens(raw) == "Hello there, how are you?")
    }

    @Test func joinsConfidentSegmentsWithSingleSpaces() {
        let text = TranscriptFilter.join([seg(" Fix the login bug. "), seg("Then run the tests.")])
        #expect(text == "Fix the login bug. Then run the tests.")
    }

    @Test func dropsLowConfidenceSegments() {
        let segments = [
            seg("Real sentence."),
            seg("tv mumbling", logprob: -1.4),
            seg("ghost words", noSpeech: 0.8),
            seg("the the the the the", compression: 3.1),
        ]
        #expect(TranscriptFilter.join(segments) == "Real sentence.")
    }

    @Test func silenceHallucinationsBecomeEmpty() {
        #expect(TranscriptFilter.join([seg("Thank you.")]) == "")
        #expect(TranscriptFilter.join([seg("Thanks for watching!")]) == "")
        #expect(TranscriptFilter.join([seg("[BLANK_AUDIO]")]) == "")
        #expect(TranscriptFilter.join([seg("you")]) == "")
    }

    @Test func realSentencesEndingInThanksSurvive() {
        let text = TranscriptFilter.join([seg("Please rewrite the intro, thank you.")])
        #expect(text == "Please rewrite the intro, thank you.")
    }

    @Test func emptyInputIsEmpty() {
        #expect(TranscriptFilter.join([]) == "")
        #expect(TranscriptFilter.join([seg("<|nospeech|>")]) == "")
    }
}
