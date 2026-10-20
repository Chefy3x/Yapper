import Testing
import Foundation
import SQLite3

// MARK: - Audio conditioning

struct AudioConditionerTests {
    private let rate = 16_000.0

    private func noise(_ seconds: Double, level: Float = 0.002) -> [Float] {
        var gen = SystemRandomNumberGenerator()
        return (0..<Int(seconds * rate)).map { _ in Float.random(in: -level...level, using: &gen) }
    }

    private func tone(_ seconds: Double, amplitude: Float) -> [Float] {
        (0..<Int(seconds * rate)).map { amplitude * sin(Float($0) * 2 * .pi * 220 / Float(rate)) }
    }

    @Test func trimsTheEdgesAndShortensLongPauses() {
        let audio = noise(1) + tone(1, amplitude: 0.05) + noise(4) + tone(1, amplitude: 0.05) + noise(1)
        let out = AudioConditioner.condition(audio, sampleRate: rate)
        let seconds = Double(out.samples.count) / rate
        // pad + 1 speech + 1.0 kept pause + 1 speech + pad
        let expected = 3 + 2 * AudioConditioner.edgePad
        #expect(abs(seconds - expected) < 0.1)
        #expect(abs(out.removedSeconds - (8 - expected)) < 0.1)
    }

    @Test func liftsQuietSpeechWithoutClipping() {
        let audio = noise(0.5, level: 0.001) + tone(1, amplitude: 0.02) + noise(0.5, level: 0.001)
        let out = AudioConditioner.condition(audio, sampleRate: rate)
        #expect(out.gain > 4)
        #expect(out.samples.map(abs).max()! <= AudioConditioner.peakCeiling)
    }

    @Test func leavesLoudSpeechAtItsLevel() {
        let audio = tone(1, amplitude: 0.5)
        let out = AudioConditioner.condition(audio, sampleRate: rate)
        #expect(out.gain == 1)
        #expect(out.samples.count == audio.count)
    }

    @Test func keepsASoftLastPhraseAfterAPause() {
        // Loud speech, a short pause, then a soft trailing phrase under the voicing gate:
        // the shape of a quiet mic and "…dot dot dot. I don't know why."
        let audio = tone(2, amplitude: 0.03) + noise(0.4) + tone(1, amplitude: 0.011) + noise(0.6)
        let out = AudioConditioner.condition(audio, sampleRate: rate)
        let keptSeconds = Double(out.samples.count) / rate
        #expect(keptSeconds >= 3.4 + AudioConditioner.edgePad - 0.05)
    }

    @Test func keepsShortPausesWhole() {
        let audio = tone(1, amplitude: 0.05) + noise(1.2) + tone(1, amplitude: 0.05)
        let out = AudioConditioner.condition(audio, sampleRate: rate)
        #expect(out.samples.count == audio.count)
    }

    @Test func returnsSilenceUntouched() {
        let audio = noise(1)
        let out = AudioConditioner.condition(audio, sampleRate: rate)
        #expect(out.samples == audio)
        #expect(out.gain == 1)
    }
}

// MARK: - Learning from edits

struct EditLearnerTests {
    private static let dictionary: Set<String> = [
        "ask", "cloud", "about", "it", "their", "there", "going", "open", "now", "so", "we", "go",
        "send", "the", "file", "deploy", "to", "talk", "hi", "team", "and", "then", "a", "b", "c", "d", "e",
        "one", "two", "three", "four", "five", "six", "seven", "check", "with", "today", "please",
    ]
    private func known(_ word: String) -> Bool { Self.dictionary.contains(word.lowercased()) }

    private func learn(_ delivered: String, to edited: String, baseline: String? = nil) -> [LearnedWord] {
        EditLearner.learn(delivered: delivered, baseline: baseline ?? delivered, edited: edited,
                          isDictionaryWord: known)
    }

    @Test func learnsANameSwappedForAnOrdinaryWord() {
        let learned = learn("ask cloud about it", to: "ask Claude about it")
        #expect(learned == [LearnedWord(heard: "cloud", typed: "Claude", makesRule: false)])
    }

    @Test func makesARuleWhenWhisperHeardANonWord() {
        let learned = learn("deploy to vercell today", to: "deploy to Vercel today")
        #expect(learned == [LearnedWord(heard: "vercell", typed: "Vercel", makesRule: true)])
    }

    @Test func learnsACapitalisationFix() {
        let learned = learn("open yapper now", to: "open Yapper now")
        #expect(learned == [LearnedWord(heard: "yapper", typed: "Yapper", makesRule: true)])
    }

    @Test func ignoresGrammarFixes() {
        #expect(learn("their going now", to: "there going now").isEmpty)
        #expect(learn("so we go", to: "So we go").isEmpty)
    }

    @Test func ignoresAWordSwappedForSomethingElseEntirely() {
        #expect(learn("send the file now", to: "send the Zebulon now").isEmpty)
    }

    @Test func ignoresRewrites() {
        #expect(learn("ask cloud about it today", to: "please check with Claude").isEmpty)
        #expect(learn("ask cloud about it", to: "ask Claude Code about it").isEmpty)
    }

    @Test func givesUpPastFourFixes() {
        let delivered = "one aa two bb three cc four dd five ee six seven eight nine"
        let edited = "one Aax two Bbx three Ccx four Ddx five Eex six seven eight nine"
        #expect(learn(delivered, to: edited).isEmpty)
    }

    @Test func findsTheDictationInsideALongerField() {
        let learned = learn("ask cloud about it", to: "Hi team. ask Claude about it",
                            baseline: "Hi team. ask cloud about it")
        #expect(learned.map(\.typed) == ["Claude"])
    }

    @Test func ignoresTextTypedAfterTheDictation() {
        let learned = learn("ask cloud about it", to: "ask Claude about it and then go")
        #expect(learned.map(\.typed) == ["Claude"])
    }

    @Test func aGrammarFixDoesNotCancelANameFix() {
        let learned = learn("their going to ask cloud about it", to: "there going to ask Claude about it")
        #expect(learned.map(\.typed) == ["Claude"])
    }

    @Test func noChangeLearnsNothing() {
        #expect(learn("ask cloud about it", to: "ask cloud about it").isEmpty)
    }
}

// MARK: - Words on screen

struct ScreenVocabularyTests {
    private static let dictionary: Set<String> = ["the", "reply", "about", "and", "ship", "it", "today",
                                                  "monday", "meeting", "notes", "with"]
    private func known(_ word: String) -> Bool { Self.dictionary.contains(word.lowercased()) }

    @Test func picksNamesAndJargonNotOrdinaryWords() {
        let text = "Reply to Quinlan about the WhisperKit PR and GPT5. The meeting notes. Monday with Quinlan."
        let words = ScreenVocabulary.candidates(in: text, isDictionaryWord: known)
        #expect(words.first == "Quinlan")   // most frequent
        #expect(words.contains("WhisperKit"))
        #expect(words.contains("GPT5"))
        #expect(!words.contains("Reply"))
        #expect(!words.contains("Monday"))
        #expect(!words.contains("PR"))   // an acronym seen once isn't enough
    }

    @Test func repeatedAcronymsAndUnknownLowercaseQualify() {
        let text = "the MCP server and MCP tools; run kubectl then kubectl again; xyzzy once"
        let words = ScreenVocabulary.candidates(in: text, isDictionaryWord: known)
        #expect(words.contains("MCP"))
        #expect(words.contains("kubectl"))
        #expect(!words.contains("xyzzy"))
    }

    @Test func respectsTheLimitAndDedupesCase() {
        let text = (1...40).map { "Zork\($0)" }.joined(separator: " ") + " Qwerty qwerty"
        let words = ScreenVocabulary.candidates(in: text, limit: 10, isDictionaryWord: known)
        #expect(words.count == 10)
    }

    @Test func screenWordsYieldToTheUsersOwnTerms() {
        let prompt = TranscriptCorrector.prompt(terms: ["Yapper"], screenWords: ["WhisperKit", "yapper"])
        #expect(prompt == "WhisperKit, Yapper.")
        let tight = TranscriptCorrector.prompt(terms: ["Yapper"], screenWords: ["WhisperKit"], maxCharacters: 10)
        #expect(tight == "Yapper.")
    }
}

// MARK: - Respelling from vocabulary

struct RespellTests {
    private static let dictionary: Set<String> = ["deploy", "to", "today", "the", "with", "cloud", "apple",
                                                  "ask", "about", "it", "whisper", "kit", "use", "and"]
    private func respell(_ text: String, _ candidates: [String]) -> String {
        TranscriptCorrector.respell(text, candidates: candidates) { Self.dictionary.contains($0.lowercased()) }
    }

    @Test func fixesANearMissThatIsNotAWord() {
        #expect(respell("deploy to Vercell today.", ["Vercel"]) == "deploy to Vercel today.")
    }

    @Test func joinsTwoWordsThatSpellACandidate() {
        #expect(respell("use whisper kit, and", ["WhisperKit"]) == "use WhisperKit, and")
    }

    @Test func takesTheCandidatesCase() {
        #expect(respell("ask yapper about it", ["Yapper"]) == "ask Yapper about it")
    }

    @Test func neverRespellsOrdinaryWords() {
        #expect(respell("ask cloud about it", ["Claude"]) == "ask cloud about it")
        #expect(respell("the apple", ["Apple"]) == "the apple")
    }

    @Test func leavesAmbiguousMatchesAlone() {
        #expect(respell("ping Jonn today", ["Jon", "John"]) == "ping Jonn today")
    }

    @Test func keepsAnAcronymsCapitals() {
        #expect(respell("use the signal MCP today", ["Mcp"]) == "use the signal MCP today")
        #expect(respell("ask yapper about it", ["YAPPER"]) == "ask YAPPER about it")
    }

    @Test func neverRespellsAFarOffWord() {
        // A day of real dictations: "vibecode" came out as "viseme" because it was on screen.
        #expect(respell("you can just vibecode any app", ["viseme"]) == "you can just vibecode any app")
        #expect(respell("deploy to Vercelll today", ["Vercel"]) == "deploy to Vercel today")
    }
}

// MARK: - Wispr Flow import

struct WisprFlowImportTests {
    private func known(_ word: String) -> Bool { ["for", "get", "promotions"].contains(word.lowercased()) }

    @Test func mapsWordsCorrectionsAndSkipsSnippets() {
        let entries: [WisprFlowImport.Entry] = [
            .init(phrase: "Yapper", replacement: nil, observed: nil, isSnippet: false, isDeleted: false),
            .init(phrase: "Zephyra", replacement: nil, observed: "Zefira", isSnippet: false, isDeleted: false),
            .init(phrase: "Fore", replacement: nil, observed: "for", isSnippet: false, isDeleted: false),
            .init(phrase: "eleven labs", replacement: "ElevenLabs", observed: nil, isSnippet: false, isDeleted: false),
            .init(phrase: "my address", replacement: "1 Example Street", observed: nil, isSnippet: true, isDeleted: false),
            .init(phrase: "Gone", replacement: nil, observed: nil, isSnippet: false, isDeleted: true),
        ]
        let plan = WisprFlowImport.plan(entries, isDictionaryWord: known)
        #expect(plan.terms == ["Yapper", "Zephyra", "Fore", "ElevenLabs"])
        #expect(plan.rules == [Replacement(heard: "Zefira", typed: "Zephyra"),
                               Replacement(heard: "eleven labs", typed: "ElevenLabs")])
        #expect(plan.skippedSnippets == 1)
    }

    @Test func readsWisprFlowsDictionaryTable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flow-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let sql = """
        CREATE TABLE "Dictionary" (`id` VARCHAR(36) NOT NULL PRIMARY KEY, `phrase` VARCHAR(255) NOT NULL, `replacement` VARCHAR(255), `isDeleted` TINYINT(1) NOT NULL DEFAULT 0, `isSnippet` TINYINT(1) NOT NULL DEFAULT 0, `observedSource` VARCHAR(255));
        INSERT INTO Dictionary VALUES ('1', 'Yapper', NULL, 0, 0, NULL);
        INSERT INTO Dictionary VALUES ('2', 'Zephyra', '', 0, 0, 'Zefira');
        INSERT INTO Dictionary VALUES ('3', 'sig', 'Signature', 0, 1, NULL);
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let entries = try WisprFlowImport.readEntries(from: url)
        #expect(entries.count == 3)
        #expect(entries[1] == .init(phrase: "Zephyra", replacement: nil, observed: "Zefira", isSnippet: false, isDeleted: false))
        #expect(entries[2].isSnippet)
    }

    @Test func missingDatabaseSaysSo() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).sqlite")
        #expect(throws: WisprFlowImport.ImportError.self) { try WisprFlowImport.readEntries(from: url) }
    }
}

// MARK: - Vocabulary: learned words and imports

@MainActor
struct LearnedVocabularyTests {
    private func tempStore() -> VocabularyStore {
        VocabularyStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("vocab-\(UUID().uuidString).json"))
    }

    @Test func applyThenUndoRestoresTheVocabulary() {
        let store = tempStore()
        store.addTerm("Existing")
        store.addReplacement(heard: "vercell", typed: "Versel")
        store.applyLearned([LearnedWord(heard: "cloud", typed: "Claude", makesRule: false),
                            LearnedWord(heard: "vercell", typed: "Vercel", makesRule: true)])
        #expect(store.terms == ["Existing", "Claude", "Vercel"])
        #expect(store.replacements.map(\.typed) == ["Vercel"])
        #expect(store.recentlyLearned?.words == ["Claude", "Vercel"])

        store.undoLearned()
        #expect(store.terms == ["Existing"])
        #expect(store.replacements.map(\.typed) == ["Versel"])
        #expect(store.recentlyLearned == nil)
    }

    @Test func mergeCountsOnlyWhatIsNew() {
        let store = tempStore()
        store.addTerm("Yapper")
        let added = store.merge(terms: ["yapper", "Zephyra"], rules: [Replacement(heard: "Zefira", typed: "Zephyra")])
        #expect(added.terms == 1)
        #expect(added.rules == 1)
        let again = store.merge(terms: ["Zephyra"], rules: [Replacement(heard: "zefira", typed: "Zephyra")])
        #expect(again.terms == 0)
        #expect(again.rules == 0)
    }
}

struct ParakeetSignalTests {
    @Test func quietSpeechCountsAsSignal() {
        let quiet = (0..<16_000).map { Float(sin(Double($0) / 7)) * 0.015 }   // a soft sentence on a quiet mic
        #expect(ParakeetTranscriber.hasSignal(quiet))
        let dead = [Float](repeating: 0.0001, count: 16_000)
        #expect(!ParakeetTranscriber.hasSignal(dead))
    }
}
