import Testing
import Foundation

struct SoundAlikesTests {
    /// A spot over the first occurrence of `heard` in `text`.
    private func spot(_ text: String, _ heard: String, _ term: String) -> SoundAlike {
        let r = text.range(of: heard)!
        let start = text.utf8.distance(from: text.startIndex, to: r.lowerBound)
        return SoundAlike(heard: heard, term: term, utf8: start..<(start + heard.utf8.count))
    }

    // MARK: apply

    @Test func writesTheTermOverTheHeardWords() {
        let text = "so we throw claw code up"
        #expect(SoundAlikes.apply([spot(text, "claw code", "Claude Code")], to: text) == "so we throw Claude Code up")
    }

    @Test func appliesSeveralSpotsFromTheEnd() {
        let text = "ask groc and parakey"
        let found = [spot(text, "groc", "Grok"), spot(text, "parakey", "Parakeet")]
        #expect(SoundAlikes.apply(found, to: text) == "ask Grok and Parakeet")
    }

    @Test func skipsAnOverlappingSpot() {
        let text = "the claw code"
        let found = [spot(text, "claw code", "Claude Code"), spot(text, "claw", "Claude")]
        #expect(SoundAlikes.apply(found, to: text) == "the Claude Code")
    }

    @Test func keepsMultibyteTextIntact() {
        let text = "café, then groc"
        #expect(SoundAlikes.apply([spot(text, "groc", "Grok")], to: text) == "café, then Grok")
    }

    // MARK: spots

    @Test func findsHintsOnWordBoundariesInAnyCase() {
        let hints = ["claude": ["cloud", "claw"], "qwen": ["Quinn"]]
        let found = SoundAlikes.spots(in: "Cloud said quinn's clawing claw", heardAs: hints, terms: ["Claude", "Qwen"])
        #expect(found.map(\.heard) == ["Cloud", "quinn", "claw"])   // not inside "clawing"
        #expect(found.map(\.term) == ["Claude", "Qwen", "Claude"])
    }

    @Test func longerHintsWinAndRemovedTermsAreIgnored() {
        let hints = ["claude code": ["claw code"], "claude": ["claw"], "vox": ["box"]]
        let found = SoundAlikes.spots(in: "throw claw code in a box", heardAs: hints, terms: ["Claude", "Claude Code"])
        #expect(found.map(\.heard) == ["claw code"])
        #expect(found.first?.term == "Claude Code")
    }

    // MARK: versions

    @Test func versionsTrimToTheWordsAroundTheSpot() {
        let text = "one two three four cloud five six seven"
        let v = SoundAlikes.versions(of: text, around: spot(text, "cloud", "Claude"), words: 2)
        #expect(v.heard == "three four cloud five six")
        #expect(v.term == "three four Claude five six")
    }

    // MARK: ContextCheck

    @Test func prefixNamesTheTerms() {
        let prefix = ContextCheck.prefix(terms: ["Claude", "Qwen"])
        #expect(prefix.contains("Claude, Qwen"))
        #expect(prefix.hasSuffix("<|im_start|>user\n"))
    }
}
