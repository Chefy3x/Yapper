import Testing

struct SpokenListsTests {
    private func list(_ s: String, _ mode: FormatMode = .chat) -> String? { SpokenLists.format(s, mode: mode) }

    @Test func ordinalsWithCommas() {
        #expect(list("So first, we got the login screen. Second, we have the settings page. Third, we have the onboarding flow.")
                == "1. We got the login screen\n2. We have the settings page\n3. We have the onboarding flow")
    }

    @Test func keepsAnIntro() {
        #expect(list("There's a few things I want to do today, first is the video edit, second is the thumbnail, and third is posting it.")
                == "There's a few things I want to do today:\n1. The video edit\n2. The thumbnail\n3. Posting it")
    }

    @Test func numberOneNumberTwo() {
        #expect(list("Number one, fix the login bug. Number two, ship the update. Number three, tell the team.")
                == "1. Fix the login bug\n2. Ship the update\n3. Tell the team")
        #expect(list("The plan: number 1, record it. Number 2, edit it.") == "The plan:\n1. Record it\n2. Edit it")
    }

    @Test func textAfterTheLastItemStaysProse() {
        #expect(list("First, pull main. Second, run the tests. Then let me know how it goes.")
                == "1. Pull main\n2. Run the tests\n\nThen let me know how it goes.")
    }

    @Test func closerEndsTheRun() {
        #expect(list("First, wash it. Second, dry it. Finally, fold it.") == "1. Wash it\n2. Dry it\n3. Fold it")
    }

    @Test func modes() {
        let text = "First, pull main. Second, run the tests."
        #expect(list(text, .document) == "- Pull main\n- Run the tests")
        #expect(list(text, .terminal) == "Pull main, Run the tests.")
    }

    @Test func leavesProseAlone() {
        #expect(list("The first time it worked, the second time it broke.") == nil)
        #expect(list("My number one priority this week is the launch video.") == nil)
        #expect(list("Second, we should talk about pricing.") == nil)          // no first
        #expect(list("First, let's ship it.") == nil)                         // one item isn't a list
        #expect(list("First of all, this is great and second of all it's cheap.") == nil)   // no second marker shape
    }
}
