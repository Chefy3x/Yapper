import Testing
import Foundation

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
    // MARK: When the recording held speech

    /// 0.3 s of quiet, `speech` seconds at speaking level, 0.3 s of quiet, at 16 kHz.
    private func recording(speech: Double, level: Float = 0.1) -> [Float] {
        let quiet = [Float](repeating: 0.002, count: 4_800)
        let voiced = (0..<Int(speech * 16_000)).map { i in level * sin(Float(i) * 0.3) * 1.414 }
        return quiet + voiced + quiet
    }

    @Test func detectsSpeechAgainstTheRoomFloor() {
        #expect(TranscriptFilter.hasSpeech(recording(speech: 0.5)))
        #expect(!TranscriptFilter.hasSpeech(recording(speech: 0.1)))   // a click, not a word
        #expect(!TranscriptFilter.hasSpeech([Float](repeating: 0.002, count: 16_000)))
        #expect(!TranscriptFilter.hasSpeech([]))
        // Talking the whole time leaves no quiet frames; it is still speech.
        #expect(TranscriptFilter.hasSpeech((0..<16_000).map { i in 0.1 * sin(Float(i) * 0.3) }))
    }

    @Test func spokenAudioKeepsUnsureWordsAndShortReplies() {
        #expect(TranscriptFilter.join([seg("Okay.")], audioHasSpeech: true) == "Okay.")
        #expect(TranscriptFilter.join([seg("Thank you.")], audioHasSpeech: true) == "Thank you.")
        #expect(TranscriptFilter.join([seg("Rename it to Kubernetes", logprob: -1.3)], audioHasSpeech: true)
                == "Rename it to Kubernetes")
    }

    @Test func spokenAudioStillDropsSilenceAndLoops() {
        let segments = [
            seg("Real sentence."),
            seg("ghost words", logprob: -1.4, noSpeech: 0.8),
            seg("the the the the the", compression: 3.1),
        ]
        #expect(TranscriptFilter.join(segments, audioHasSpeech: true) == "Real sentence.")
        #expect(TranscriptFilter.join([seg("[BLANK_AUDIO]")], audioHasSpeech: true) == "")
        #expect(TranscriptFilter.join([seg("(music)")], audioHasSpeech: true) == "")
    }
    @Test func dropsSegmentsThatStartAfterTheAudioEnds() {
        var tail = seg("Thanks for watching!")
        tail.start = 4.2
        var real = seg("Ship it today.")
        real.start = 0.4
        #expect(TranscriptFilter.join([real, tail], audioHasSpeech: true, audioSeconds: 3.1) == "Ship it today.")
        // Without a known length nothing is dropped on timing alone.
        #expect(TranscriptFilter.join([real, tail], audioHasSpeech: true) == "Ship it today. Thanks for watching!")
    }
}
