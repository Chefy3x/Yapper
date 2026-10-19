import Testing
import Foundation

// Snippets: a spoken trigger types saved text. Sample data is invented.
@MainActor
struct SnippetTests {

    private func snip(_ trigger: String, _ expansion: String) -> Snippet {
        Snippet(trigger: trigger, expansion: expansion)
    }

    private func makeStore() -> SnippetStore {
        SnippetStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("snippets-\(UUID().uuidString).json"))
    }

    @Test func aDictationThatIsOnlyTheTriggerBecomesExactlyTheSnippet() {
        let s = [snip("my calendar link", "https://cal.example.com/sam/30min")]
        #expect(SnippetExpander.expand("My calendar link.", snippets: s).text == "https://cal.example.com/sam/30min")
        #expect(SnippetExpander.expand("my, calendar link!", snippets: s).text == "https://cal.example.com/sam/30min")
    }

    @Test func insideASentenceTheSnippetReplacesTheTrigger() {
        let s = [snip("my email", "sam@example.com")]
        let out = SnippetExpander.expand("Send it to my email please.", snippets: s)
        #expect(out.text == "Send it to sam@example.com please.")
        #expect(out.used == [s[0].id])
    }

    @Test func triggersMatchWholeWordsOnly() {
        let s = [snip("sig", "— Sam")]
        #expect(SnippetExpander.expand("The signal is strong.", snippets: s).text == "The signal is strong.")
        #expect(SnippetExpander.expand("Thanks, sig", snippets: s).text == "Thanks, — Sam")
    }

    @Test func longerTriggersWinAndExpansionsAreNotReExpanded() {
        let s = [snip("my email", "sam@example.com"),
                 snip("my work email", "my email at work: sam@work.example")]
        let out = SnippetExpander.expand("Use my work email for this.", snippets: s)
        #expect(out.text == "Use my email at work: sam@work.example for this.")
        #expect(out.used.count == 1)
    }

    @Test func multiLineExpansionsAndTemplateCharactersArriveIntact() {
        let s = [snip("standup template", "Yesterday:\n- \nToday:\n- \nCost: $1 \\ $2")]
        #expect(SnippetExpander.expand("Standup template", snippets: s).text == "Yesterday:\n- \nToday:\n- \nCost: $1 \\ $2")
        #expect(SnippetExpander.expand("Here: standup template", snippets: s).text == "Here: Yesterday:\n- \nToday:\n- \nCost: $1 \\ $2")
    }

    @Test func nothingMatchingLeavesTextAlone() {
        let s = [snip("my address", "1 Example Street")]
        let out = SnippetExpander.expand("No snippets in here.", snippets: s)
        #expect(out.text == "No snippets in here.")
        #expect(out.used.isEmpty)
    }

    @Test func storeRejectsEmptyAndDuplicateTriggers() throws {
        let store = makeStore()
        try store.add(trigger: "My Email", expansion: "sam@example.com")
        #expect(throws: SnippetStore.EditError.self) { try store.add(trigger: "my email.", expansion: "other") }
        #expect(throws: SnippetStore.EditError.emptyTrigger) { try store.add(trigger: " … ", expansion: "x") }
        #expect(throws: SnippetStore.EditError.emptyExpansion) { try store.add(trigger: "sign off", expansion: "  ") }
        #expect(store.snippets.count == 1)
    }

    @Test func storePersistsEditsAndCountsUses() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snippets-\(UUID().uuidString).json")
        let store = SnippetStore(url: url)
        let s = try store.add(trigger: "my email", expansion: "sam@example.com")
        try store.update(s.id, trigger: "email me", expansion: "sam@example.org")
        #expect(store.expand("Email me.") == "sam@example.org")
        #expect(store.expand("Nothing here") == "Nothing here")

        let reloaded = SnippetStore(url: url)
        #expect(reloaded.snippets.first?.trigger == "email me")
        #expect(reloaded.snippets.first?.uses == 1)
        reloaded.remove(s.id)
        #expect(SnippetStore(url: url).snippets.isEmpty)
    }
}
