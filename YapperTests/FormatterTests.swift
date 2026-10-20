import Testing
import Foundation

struct FormatCuesTests {
    @Test func spotsSelfCorrections() {
        #expect(FormatCues.needsFormatting("Let's meet at 3, no wait, 4 tomorrow."))
        #expect(FormatCues.needsFormatting("Send it to Mike, I mean Sarah, today."))
        #expect(!FormatCues.hasCorrection("It's okay if it's slow. I mean, I'm doing other things anyway."))
        #expect(!FormatCues.hasCorrection("I mean, that works for me."))
        #expect(FormatCues.hasCorrection("Use the red one. I meant the blue one."))
        #expect(FormatCues.needsFormatting("Check the logs and, scratch that, restart it."))
        #expect(FormatCues.afterLastCorrection("at 2, no wait, 3, no wait, 4 today") == ", 4 today")
    }

    @Test func spotsLists() {
        #expect(FormatCues.needsFormatting("I need three things for the trip and that's it."))
        #expect(FormatCues.needsFormatting("First update the readme, second push the branch."))
        #expect(FormatCues.needsFormatting("Okay, number one, we ship it tonight."))
    }

    @Test func leavesOrdinaryDictationAlone() {
        #expect(!FormatCues.needsFormatting("Can you take a look at this when you get a chance?"))
        #expect(!FormatCues.needsFormatting("I actually think that's fine."))
        #expect(!FormatCues.needsFormatting("I mean it."))   // too short to be worth it
        #expect(!FormatCues.needsFormatting("This is the first draft of the post."))
    }
}

struct FormatModeTests {
    @Test func picksTheModeFromTheApp() {
        #expect(FormatMode.forApp(bundleID: "com.apple.Terminal") == .terminal)
        #expect(FormatMode.forApp(bundleID: "com.googlecode.iterm2") == .terminal)
        #expect(FormatMode.forApp(bundleID: "com.apple.mail") == .email)
        #expect(FormatMode.forApp(bundleID: "md.obsidian") == .document)
        #expect(FormatMode.forApp(bundleID: "com.anthropic.claudefordesktop") == .chat)
        #expect(FormatMode.forApp(bundleID: nil) == .chat)
    }

    @Test func terminalsNeverGetALineBreak() {
        #expect(!FormatMode.terminal.allowsLineBreaks)
        #expect(!FormatPrompt.prefix(mode: .terminal).contains("1. My passport"))
        #expect(FormatPrompt.prefix(mode: .chat).contains("1. My passport\n2. The charger"))
        #expect(FormatPrompt.prefix(mode: .document).contains("- My passport"))
    }

    @Test func promptEndsReadyForTheAnswer() {
        let prompt = FormatPrompt.build(text: "hello there", mode: .chat)
        #expect(prompt.hasSuffix("<|im_start|>user\nhello there<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"))
        #expect(FormatPrompt.clean("<think>\nhm\n</think>\n\nHi.<|im_end|>") == "Hi.")
    }
}

struct FormatGuardTests {
    private func check(_ input: String, _ output: String, _ mode: FormatMode = .chat) -> FormatGuard.Verdict {
        FormatGuard.check(input: input, output: output, mode: mode)
    }

    @Test func acceptsAnAppliedCorrection() {
        #expect(check("Let's meet at 3, no wait, 4 tomorrow.", "Let's meet at 4 tomorrow.")
                == .accept("Let's meet at 4 tomorrow."))
    }

    @Test func acceptsAList() {
        let input = "I need three things. First, my passport. Second, the charger. And third, a jacket."
        let output = "I need three things:\n1. My passport\n2. The charger\n3. A jacket"
        #expect(check(input, output) == .accept(output))
    }

    @Test func refusesKeepingTheAbandonedVersion() {
        guard case .reject = check("Tell Jordan I'll be late, I mean, tell Priya I'll be late.", "Tell Jordan I'll be late.")
        else { Issue.record("kept the wrong name"); return }
    }

    @Test func refusesAddedOrChangedWords() {
        guard case .reject = check("First, call mom. Second, buy milk.", "1. Call your mom\n2. Buy milk")
        else { Issue.record("allowed an added word"); return }
        guard case .reject = check("Let's meet at 3, no wait, 4 tomorrow.", "Let's meet at four tomorrow.")
        else { Issue.record("allowed a respelled number"); return }
    }

    @Test func refusesDroppingContentFromAList() {
        guard case .reject = check("So the plan is, first, we fix it, and second, we ship it.",
                                   "1. We fix it\n2. We ship it")
        else { Issue.record("allowed a dropped lead-in"); return }
    }

    @Test func refusesLineBreaksInATerminal() {
        guard case .reject = check("First, pull main. Second, run tests.", "1. Pull main\n2. Run tests", .terminal)
        else { Issue.record("allowed a newline in a terminal"); return }
    }

    @Test func refusesPreambleAndEmptiness() {
        guard case .reject = check("First, a. Second, b.", "Here is the list: a, b") else { Issue.record("preamble"); return }
        guard case .reject = check("First, a. Second, b.", "   ") else { Issue.record("empty"); return }
    }

    @Test func noChangeIsUnchanged() {
        #expect(check("I mean it, this is good.", "I mean it, this is good.") == .unchanged)
        #expect(check("I mean it, this is good.", "I mean it. This is good.") == .unchanged)
    }

    @Test func fillerMayGoFromAList() {
        let output = "So the plan is:\n1. We fix it\n2. We ship it"
        #expect(check("Okay so the plan is, number one, we fix it, and number two, we ship it.", output) == .accept(output))
    }
}

struct FormatPlanTests {
    @Test func correctionsGetTheFullBudget() {
        #expect(FormatEngine.plan("Let's meet at 3, no wait, 4 tomorrow.", cleanup: true) == FormatEngine.budget)
        #expect(FormatEngine.plan("I need three things for the trip today.", cleanup: false) == nil)   // rules do lists
        let long = Array(repeating: "we should ship it", count: 20).joined(separator: " ") + ", no wait, tomorrow"
        #expect(FormatEngine.plan(long, cleanup: false) == nil)
    }

    @Test func fillerAloneGetsLittleAndOnlyWhenShort() {
        #expect(FormatEngine.plan("So I was like thinking we could go.", cleanup: true)
                == (FormatEngine.fillerViaModel ? FormatEngine.fillerBudget : nil))
        let long = Array(repeating: "so we were like talking", count: 10).joined(separator: " ")
        #expect(FormatEngine.plan(long, cleanup: true) == nil)
        #expect(FormatEngine.plan("So I was like thinking we could go.", cleanup: false) == nil)
    }

    @Test func plainDictationSkipsTheModel() {
        #expect(FormatEngine.plan("Can you take a look at this when you get a chance?", cleanup: true) == nil)
        #expect(FormatEngine.plan("Ship it.", cleanup: true) == nil)
    }
}
