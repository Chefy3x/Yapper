import Testing
@testable import Yapper

struct PunctuationTests {
    private func finish(_ s: String, _ mode: FormatMode = .chat) -> String { Punctuation.finish(s, mode: mode) }

    @Test func closesTheLastSentence() {
        #expect(finish("this shit looks awful") == "this shit looks awful.")
        #expect(finish("Yeah, so when I test that") == "Yeah, so when I test that.")
        #expect(finish("make sure that the rigging opens wider,") == "make sure that the rigging opens wider.")
        #expect(finish("Done already.") == "Done already.")
        #expect(finish("Is it done?") == "Is it done?")
    }

    @Test func asksWhenItsAQuestion() {
        #expect(finish("The teeth are off. Does that make sense") == "The teeth are off. Does that make sense?")
        #expect(finish("So can you add the price quote") == "So can you add the price quote?")
        #expect(finish("how do we fix the layout") == "how do we fix the layout?")
        #expect(finish("What's another one") == "What's another one?")
        #expect(finish("What we're gonna do is keep it") == "What we're gonna do is keep it.")
        #expect(finish("How it works is simple") == "How it works is simple.")
        #expect(finish("Doesn't have to be too detailed") == "Doesn't have to be too detailed.")
    }

    @Test func leavesListsFragmentsAndShellsAlone() {
        #expect(finish("1. Fix the login\n2. Add the settings page") == "1. Fix the login\n2. Add the settings page")
        #expect(finish("to") == "to")
        #expect(finish("Let's do a") == "Let's do a")
        #expect(finish("I want to rig it first but") == "I want to rig it first but")
        #expect(finish("git status", .terminal) == "git status")
    }

    @Test func capitalisesI() {
        #expect(finish("I like it but i think i'm wrong.") == "I like it but I think I'm wrong.")
        #expect(finish("it is, i.e. the thing.") == "it is, i.e. the thing.")
        #expect(finish("the ui is fine.") == "the ui is fine.")
    }

    @Test func capitalisesSentenceStarts() {
        #expect(finish("even Miss Rachel. and I feel like it.") == "even Miss Rachel. And I feel like it.")
        #expect(finish("works? yes it does.") == "works? Yes it does.")
        #expect(finish("open AppState.swift and look.") == "open AppState.swift and look.")
        #expect(finish("like e.g. the cassette.") == "like e.g. the cassette.")
    }
}
