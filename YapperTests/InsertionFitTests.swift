import Testing

struct InsertionFitTests {
    private static let dictionary: Set<String> = ["send", "it", "tomorrow", "and", "the", "also", "we", "can", "maybe"]
    private func fit(_ text: String, before: String?, after: String? = "") -> String {
        InsertionFit.fit(text, before: before, after: after) { Self.dictionary.contains($0) }
    }

    @Test func startOfFieldOrSentenceKeepsTheSentence() {
        #expect(fit("Send it tomorrow.", before: "") == "Send it tomorrow.")
        #expect(fit("Send it tomorrow.", before: "Looks good. ") == "Send it tomorrow.")
        #expect(fit("Send it tomorrow.", before: "Looks good.") == " Send it tomorrow.")
        #expect(fit("Send it tomorrow.", before: "Hi team,\n") == "Send it tomorrow.")
        #expect(fit("Send it tomorrow.", before: "~ $ ") == "Send it tomorrow.")
        #expect(fit("Send it tomorrow.", before: "Notes\n- ") == "Send it tomorrow.")
    }

    @Test func midSentenceContinuesIt() {
        #expect(fit("Send it tomorrow.", before: "Looks good, ") == "send it tomorrow.")
        #expect(fit("Send it tomorrow.", before: "Looks good and") == " send it tomorrow.")
        #expect(fit("Also we can ship.", before: "(") == "also we can ship.")
    }

    @Test func keepsNamesAcronymsAndI() {
        #expect(fit("Priya can review it.", before: "ask ") == "Priya can review it.")
        #expect(fit("I think so.", before: "and ") == "I think so.")
        #expect(fit("GPT is fine.", before: "and ") == "GPT is fine.")
    }

    @Test func textAfterTheCursor() {
        #expect(fit("Maybe tomorrow.", before: "We could ship it ", after: "if the tests pass.") == "maybe tomorrow ")
        #expect(fit("Tomorrow.", before: "Ship it ", after: ", then tell me.") == "tomorrow")
    }

    @Test func listsGoOnTheirOwnLine() {
        let list = "1. Pull main\n2. Run the tests"
        #expect(fit(list, before: "Steps:") == "\n" + list)
        #expect(fit(list, before: "Steps:\n") == list)
        #expect(fit(list, before: "") == list)
    }

    @Test func unknownContextChangesNothing() {
        #expect(fit("Send it tomorrow.", before: nil) == "Send it tomorrow.")
    }
}
