import Testing

struct DisfluencyTests {
    private func clean(_ s: String) -> String { Disfluency.clean(s) }

    @Test func dropsFillerSounds() {
        #expect(clean("Um, I think we should go.") == "I think we should go.")
        #expect(clean("So, um, I think we should go.") == "So I think we should go.")
        #expect(clean("I think, uh.") == "I think.")
        #expect(clean("It's uh fine") == "It's fine")
    }

    @Test func dropsRepeatedWordsAndPhrases() {
        #expect(clean("I I think the the plan works.") == "I think the plan works.")
        #expect(clean("The the dog barked.") == "The dog barked.")
        #expect(clean("I think I think we should ship it.") == "I think we should ship it.")
        #expect(clean("we need to we need to fix it") == "we need to fix it")
        #expect(clean("I feel like it's it's it's it's way too much.") == "I feel like it's way too much.")
        #expect(clean("I think I think I think so") == "I think so")
    }

    @Test func keepsDeliberateRepeats() {
        #expect(clean("It's very very good.") == "It's very very good.")
        #expect(clean("No no, that's fine.") == "No no, that's fine.")
        #expect(clean("He said that that was wrong.") == "He said that that was wrong.")
        #expect(clean("Done. Done.") == "Done. Done.")
        #expect(clean("and then blah blah blah") == "and then blah blah blah")
    }

    @Test func fixesStutters() {
        #expect(clean("b-but we can try") == "but we can try")
        #expect(clean("w- we can try") == "we can try")
        #expect(clean("I-I don't know") == "I don't know")
        #expect(clean("check your e-mail and well-being") == "check your e-mail and well-being")
    }

    @Test func dropsOnlyTheSafeFillers() {
        #expect(clean("I have like three of them") == "I have three of them")
        #expect(clean("It was, you know, huge.") == "It was huge.")
        #expect(clean("but yeah, it works") == "but, it works" || clean("but yeah, it works") == "but it works")
        #expect(clean("I like it a lot") == "I like it a lot")
        #expect(clean("Do you know the way?") == "Do you know the way?")
        #expect(clean("I feel like it works") == "I feel like it works")
    }

    @Test func leavesCleanTextAlone() {
        let text = "Can you take a look at the build when you get a chance?"
        #expect(clean(text) == text)
        #expect(clean("") == "")
    }
}

struct DisfluencyWordsTests {
    @Test func reduplicatedWordsSurvive() {
        #expect(Disfluency.clean("okay bye-bye!") == "okay bye-bye!")
        #expect(Disfluency.clean("it was so-so") == "it was so-so")
        #expect(Disfluency.clean("we-we tried") == "we tried")
    }
}

struct RestartTests {
    private func clean(_ s: String) -> String { Disfluency.clean(s) }

    @Test func dropsTheAbandonedStart() {
        #expect(clean("we need to worry about the other signs like the other sounds that come after")
                == "we need to worry about the other sounds that come after")
        #expect(clean("Nah, I don't like the I don't like that.") == "Nah, I don't like that.")
        #expect(clean("It doesn't look like we're it doesn't look right when we move")
                == "It doesn't look right when we move")
        #expect(clean("I like the thud like I like that little thud sound") == "I like that little thud sound")
    }

    @Test func keepsParallelPhrasing() {
        #expect(clean("It's not too low and it's not high at all.") == "It's not too low and it's not high at all.")
        #expect(clean("use them as a timer use them to schedule tasks") == "use them as a timer use them to schedule tasks")
        #expect(clean("open source isn't necessarily open source") == "open source isn't necessarily open source")
        #expect(clean("our CTRs are good, our CPCs are good") == "our CTRs are good, our CPCs are good")
        #expect(clean("should we keep this should we change this") == "should we keep this should we change this")
        #expect(clean("I like the drawing of like the car park") == "I like the drawing of like the car park")
    }
}
