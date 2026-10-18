import Testing

// Variables and @ files for dictating code: names come off the screen, spoken runs of their
// words are typed the way the code spells them, and nothing else in the sentence moves.
struct CodeWordsTests {
    private let screen = """
    final class SessionStore {
        var userId: String
        func fetchAllRows(limit: Int) { self.retryCount = 0 }
        let maxRetry_count = 3
        var isOn = false
    }
    // see AppState.swift and README.md, and http_server.py
    """

    @Test func splitsNamesIntoTheirSpokenWords() {
        #expect(CodeWords.words(of: "userId") == ["user", "id"])
        #expect(CodeWords.words(of: "HTTPServer") == ["http", "server"])
        #expect(CodeWords.words(of: "userID") == ["user", "id"])
        #expect(CodeWords.words(of: "fetch_all_rows") == ["fetch", "all", "rows"])
        #expect(CodeWords.words(of: "parseV2Response") == ["parse", "v", "2", "response"])
    }

    @Test func readsMultiWordNamesAndFilesOffTheScreen() {
        let names = CodeWords.identifiers(in: screen)
        #expect(names.contains("SessionStore"))
        #expect(names.contains("userId"))
        #expect(names.contains("fetchAllRows"))
        #expect(names.contains("retryCount"))
        #expect(names.contains("AppState.swift"))
        #expect(names.contains("http_server.py"))
        #expect(!names.contains("isOn"))       // two function-ish words: would eat "is on"
        #expect(!names.contains("self"))       // one word: left to the speech model
        #expect(!names.contains("final"))
    }

    @Test func typesSpokenNamesTheWayTheCodeSpellsThem() {
        let names = CodeWords.identifiers(in: screen)
        let out = CodeWords.apply("Check user id in the session store and call fetch all rows.",
                                  identifiers: names, tagFiles: false)
        #expect(out == "Check userId in the SessionStore and call fetchAllRows.")
    }

    @Test func capitalisedSentenceStartStillMatches() {
        #expect(CodeWords.apply("User id is nil here", identifiers: ["userId"], tagFiles: false) == "userId is nil here")
    }

    @Test func wordsSplitByPunctuationAreNotJoined() {
        #expect(CodeWords.apply("Ask the user, id first", identifiers: ["userId"], tagFiles: false) == "Ask the user, id first")
    }

    @Test func filesBecomeAtMentionsWhereTheAppTakesThem() {
        let names = ["AppState.swift", "http_server.py"]
        #expect(CodeWords.apply("Look at app state dot swift please", identifiers: names, tagFiles: true)
                == "Look @AppState.swift please")
        #expect(CodeWords.apply("Open app state dot swift", identifiers: names, tagFiles: true)
                == "Open AppState.swift")
        #expect(CodeWords.apply("Look at app state", identifiers: names, tagFiles: true) == "Look @AppState.swift")
        #expect(CodeWords.apply("Look at AppState.swift", identifiers: names, tagFiles: true) == "Look @AppState.swift")
        #expect(CodeWords.apply("Fix http server dot py", identifiers: names, tagFiles: true) == "Fix http_server.py")
    }

    @Test func withoutMentionsAFileIsJustTypedRight() {
        #expect(CodeWords.apply("Look at app state dot swift", identifiers: ["AppState.swift"], tagFiles: false)
                == "Look at AppState.swift")
        // "at app state" alone is prose in an app without mentions.
        #expect(CodeWords.apply("Look at app state", identifiers: ["AppState.swift"], tagFiles: false) == "Look at app state")
    }

    @Test func longerNamesWin() {
        let out = CodeWords.apply("call fetch all rows now", identifiers: ["fetchAll", "fetchAllRows"], tagFiles: false)
        #expect(out == "call fetchAllRows now")
    }

    @Test func nothingOnScreenChangesNothing() {
        #expect(CodeWords.apply("user id", identifiers: [], tagFiles: true) == "user id")
    }

    @Test func knowsCodingAppsAndWhichTakeMentions() {
        #expect(CodeWords.isCodingApp(bundleID: "com.microsoft.VSCode"))
        #expect(CodeWords.isCodingApp(bundleID: "com.apple.Terminal"))
        #expect(CodeWords.isCodingApp(bundleID: "com.anthropic.claudefordesktop"))
        #expect(!CodeWords.isCodingApp(bundleID: "com.apple.mail"))
        #expect(CodeWords.tagsFiles(bundleID: "com.todesktop.230313mzl4w4u92"))
        #expect(!CodeWords.tagsFiles(bundleID: "com.apple.dt.Xcode"))
    }
}
