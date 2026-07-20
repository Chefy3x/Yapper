import Testing

// TextCleaner is the layer between "what the copy button captured" and "what gets spoken".
// Regressions here are silent in daily use — the app keeps working, it just reads garbage —
// so every markdown rule the spec cares about is pinned down here.
struct TextCleanerTests {

    // MARK: - Fenced code (spec: silently skipped, no announcement)

    @Test func stripsFencedCodeBlocks() {
        let input = "Before.\n```swift\nlet x = 1\nprint(x)\n```\nAfter."
        #expect(TextCleaner.clean(input) == "Before.\nAfter.")
    }

    @Test func stripsTildeFences() {
        let input = "Before.\n~~~\ncode here\n~~~\nAfter."
        #expect(TextCleaner.clean(input) == "Before.\nAfter.")
    }

    @Test func unclosedFenceDropsRestOfText() {
        let input = "Kept.\n```\nnever closed\nstill code"
        #expect(TextCleaner.clean(input) == "Kept.")
    }

    @Test func backtickFenceInsideTildeFenceStaysCode() {
        let input = "Before.\n~~~\n```\ninner\n```\n~~~\nAfter."
        #expect(TextCleaner.clean(input) == "Before.\nAfter.")
    }

    @Test func codeOnlyResponseCleansToEmpty() {
        let input = "```python\nprint('hi')\n```"
        #expect(TextCleaner.clean(input).isEmpty)
    }

    // MARK: - Block markers

    @Test func stripsHeadingMarkers() {
        #expect(TextCleaner.clean("## The Plan") == "The Plan")
        #expect(TextCleaner.clean("###### Deep heading") == "Deep heading")
    }

    @Test func stripsListMarkers() {
        #expect(TextCleaner.clean("- dash item") == "dash item")
        #expect(TextCleaner.clean("* star item") == "star item")
        #expect(TextCleaner.clean("+ plus item") == "plus item")
        #expect(TextCleaner.clean("1. numbered") == "numbered")
        #expect(TextCleaner.clean("2) parens") == "parens")
    }

    @Test func stripsBlockquoteMarkers() {
        #expect(TextCleaner.clean("> quoted text") == "quoted text")
    }

    @Test func dropsHorizontalRules() {
        #expect(TextCleaner.clean("para one\n---\npara two") == "para one\n\npara two")
        #expect(TextCleaner.clean("para one\n***\npara two") == "para one\n\npara two")
    }

    @Test func dropsTableRows() {
        let input = "Intro.\n| a | b |\n|---|---|\n| 1 | 2 |\nAfter."
        #expect(TextCleaner.clean(input) == "Intro.\n\nAfter.")
    }

    // MARK: - Inline formatting

    @Test func keepsLinkTextDropsURL() {
        #expect(TextCleaner.clean("see [the docs](https://example.com/x) now") == "see the docs now")
        #expect(TextCleaner.clean("ref [style][1] link") == "ref style link")
    }

    @Test func dropsImagesEntirely() {
        #expect(TextCleaner.clean("before ![alt text](img.png) after") == "before after")
    }

    @Test func keepsInlineCodeContent() {
        #expect(TextCleaner.clean("run `swift build` locally") == "run swift build locally")
    }

    @Test func stripsEmphasisMarkers() {
        #expect(TextCleaner.clean("***a*** **b** *c* __d__ _e_ ~~f~~") == "a b c d e f")
    }

    @Test func keepsAsterisksInsideWords() {
        // (?<!\w) guards: 2*3*4 is arithmetic, not emphasis.
        #expect(TextCleaner.clean("compute 2*3*4 now") == "compute 2*3*4 now")
    }

    // MARK: - Whitespace / pauses

    @Test func collapsesBlankRunsToSingleParagraphBreak() {
        #expect(TextCleaner.clean("one\n\n\n\ntwo") == "one\n\ntwo")
    }

    @Test func keepsParagraphBreakAfterHeading() {
        // The blank line is the TTS pause per spec — it must survive cleaning.
        #expect(TextCleaner.clean("## Title\n\nBody text.") == "Title\n\nBody text.")
    }

    @Test func collapsesInternalWhitespace() {
        #expect(TextCleaner.clean("too    many\tspaces") == "too many spaces")
    }

    @Test func emptyInputCleansToEmpty() {
        #expect(TextCleaner.clean("").isEmpty)
        #expect(TextCleaner.clean("   \n\n  ").isEmpty)
    }
}
