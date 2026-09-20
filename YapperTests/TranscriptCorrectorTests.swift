import Testing
import Foundation

struct TranscriptCorrectorTests {
    private func rule(_ heard: String, _ typed: String) -> Replacement { Replacement(heard: heard, typed: typed) }

    // MARK: apply

    @Test func replacesOnWordBoundariesCaseInsensitively() {
        let out = TranscriptCorrector.apply("Open yapper and tell Yapper to yap.", replacements: [rule("yapper", "Yapper")])
        #expect(out == "Open Yapper and tell Yapper to yap.")
    }

    @Test func doesNotReplaceInsideOtherWords() {
        let out = TranscriptCorrector.apply("The cat scattered.", replacements: [rule("cat", "dog")])
        #expect(out == "The dog scattered.")
    }

    @Test func longerRulesWinOverTheirSubstrings() {
        let rules = [rule("eleven", "11"), rule("eleven labs", "ElevenLabs")]
        #expect(TranscriptCorrector.apply("use eleven labs", replacements: rules) == "use ElevenLabs")
    }

    @Test func noRulesIsIdentity() {
        #expect(TranscriptCorrector.apply("unchanged", replacements: []) == "unchanged")
    }

    // MARK: prompt

    @Test func promptJoinsTermsAsPriorContext() {
        #expect(TranscriptCorrector.prompt(terms: ["Yapper", "Bubba", "KeepCo"]) == "Yapper, Bubba, KeepCo.")
        #expect(TranscriptCorrector.prompt(terms: []) == nil)
        #expect(TranscriptCorrector.prompt(terms: ["  "]) == nil)
    }

    @Test func promptKeepsTheNewestTermsUnderTheCap() {
        let terms = (1...100).map { "term\($0)" }
        let prompt = TranscriptCorrector.prompt(terms: terms, maxCharacters: 40)!
        #expect(prompt.count <= 42)
        #expect(prompt.hasSuffix("term100."))
        #expect(!prompt.contains("term1,"))
    }

    // MARK: learn

    @Test func learnsASubstitutedWord() {
        let rules = TranscriptCorrector.learn(original: "open the yapper app", corrected: "open the Yapper app")
        #expect(rules == [rule("yapper", "Yapper")])
    }

    @Test func learnsMultiWordRuns() {
        let rules = TranscriptCorrector.learn(original: "ask 11 labs for a voice", corrected: "ask ElevenLabs for a voice")
        #expect(rules.map(\.heard) == ["11 labs"])
        #expect(rules.map(\.typed) == ["ElevenLabs"])
    }

    @Test func ignoresPureInsertionsAndDeletions() {
        #expect(TranscriptCorrector.learn(original: "fix the bug", corrected: "fix the bug now").isEmpty)
        #expect(TranscriptCorrector.learn(original: "please fix the bug", corrected: "fix the bug").isEmpty)
    }

    @Test func treatsALongRewriteAsNotACorrection() {
        let rules = TranscriptCorrector.learn(original: "one two three four five six seven",
                                              corrected: "a b c d e f g")
        #expect(rules.isEmpty)
    }

    @Test func punctuationDoesNotPolluteRules() {
        let rules = TranscriptCorrector.learn(original: "Hello bubba, how are you?", corrected: "Hello Bubba, how are you?")
        #expect(rules == [rule("bubba", "Bubba")])
    }

    @Test func identicalTextLearnsNothing() {
        #expect(TranscriptCorrector.learn(original: "same", corrected: "same").isEmpty)
    }
}

@MainActor
struct VocabularyStoreTests {
    private func tempStore() -> VocabularyStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-\(UUID().uuidString).json")
        return VocabularyStore(url: url)
    }

    @Test func termsDedupeCaseInsensitively() {
        let store = tempStore()
        store.addTerm("Yapper"); store.addTerm("yapper"); store.addTerm("  ")
        #expect(store.terms == ["Yapper"])
    }

    @Test func learningAddsRulesAndTerms() {
        let store = tempStore()
        store.record(original: "call bubba", delivered: "call bubba")
        let learned = store.learn(corrected: "call Bubba")
        #expect(learned.count == 1)
        #expect(store.replacements.map(\.typed) == ["Bubba"])
        #expect(store.terms == ["Bubba"])
        #expect(store.lastTranscript?.delivered == "call Bubba")
    }

    @Test func addingTheSameHeardUpdatesTheRule() {
        let store = tempStore()
        store.addReplacement(heard: "keep co", typed: "Keepco")
        store.addReplacement(heard: "Keep Co", typed: "KeepCo")
        #expect(store.replacements.count == 1)
        #expect(store.replacements.first?.typed == "KeepCo")
    }

    @Test func persistsAcrossInstances() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-\(UUID().uuidString).json")
        let a = VocabularyStore(url: url)
        a.addTerm("Yapper")
        a.addReplacement(heard: "yapper", typed: "Yapper")
        let b = VocabularyStore(url: url)
        #expect(b.terms == ["Yapper"])
        #expect(b.replacements.map(\.heard) == ["yapper"])
    }
}
