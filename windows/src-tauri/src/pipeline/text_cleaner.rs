//! Markdown → TTS-ready plain text — port of `Yapper/Services/TextCleaner.swift`.
//!
//! Per the Yapper spec:
//! - Fenced code blocks: silently skipped, no announcement
//! - Inline code: keep contents, drop backticks
//! - Headings, bold/italic, links, lists, blockquotes: strip markers, keep text
//! - Tables, horizontal rules, images, math: stripped/skipped
//! - Paragraphs and list items: separated by blank lines so the TTS engine
//!   inserts a natural pause
//!
//! The patterns are transcribed from the Swift originals rather than rewritten,
//! which is why this uses `fancy-regex`: the emphasis rules rely on lookaround
//! (`(?<!\w)\*…\*(?!\w)`, the guard that keeps `2*3*4` arithmetic), and the
//! `regex` crate deliberately has none.

use fancy_regex::Regex;
use std::sync::LazyLock;

pub fn clean(raw: &str) -> String {
    let normalized = raw.replace("\r\n", "\n");
    let lines: Vec<&str> = normalized.split('\n').collect();

    // 1. Strip fenced code blocks (``` ... ``` or ~~~ ... ~~~).
    let lines = strip_fenced_code(&lines);

    // 2. Per-line transforms.
    let cleaned: Vec<String> = lines.iter().map(|l| transform_line(l)).collect();

    // 3. Collapse runs of empty lines to a single blank line so paragraph
    //    pauses stay natural.
    let collapsed = collapse_blank_runs(&cleaned);

    // 4. Trim leading/trailing whitespace from the whole string.
    collapsed.join("\n").trim().to_string()
}

// MARK: - Fenced code

static FENCE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^\s{0,3}(```+|~~~+)").unwrap());

fn strip_fenced_code<'a>(lines: &[&'a str]) -> Vec<&'a str> {
    let mut out = Vec::new();
    let mut in_fence = false;
    let mut open_fence = ' ';

    for line in lines {
        if let Ok(Some(caps)) = FENCE.captures(line) {
            let marker = caps.get(1).map(|m| m.as_str()).unwrap_or("");
            let family = marker.chars().next().unwrap_or(' '); // ` or ~
            if !in_fence {
                in_fence = true;
                open_fence = family;
                continue;
            }
            // Already inside a fence: only close on matching marker family.
            if family == open_fence {
                in_fence = false;
                open_fence = ' ';
                continue;
            }
        }
        if in_fence {
            continue;
        }
        out.push(*line);
    }
    out
}

// MARK: - Per-line

static HORIZONTAL_RULE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\s*([-*_]\s*){3,}\s*$").unwrap());
static BLOCKQUOTE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^\s*>\s?").unwrap());
static HEADING: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^\s*#{1,6}\s+").unwrap());
static LIST_MARKER: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\s*([-*+]|\d+[.)])\s+").unwrap());

fn transform_line(raw_line: &str) -> String {
    // Drop horizontal rules.
    if HORIZONTAL_RULE.is_match(raw_line).unwrap_or(false) {
        return String::new();
    }

    // Drop pure table rows / separators ( | a | b | , |---|---| ).
    // Heuristic: a line that starts and ends with | is treated as a table row.
    let trimmed = raw_line.trim_matches(|c: char| c == ' ' || c == '\t');
    if trimmed.starts_with('|') && trimmed.ends_with('|') {
        return String::new();
    }

    // Strip leading blockquote markers.
    let line = BLOCKQUOTE.replace(raw_line, "");
    // Strip ATX heading markers (#, ##, ### …). Keep the heading text.
    let line = HEADING.replace(&line, "").into_owned();
    // Strip leading list markers (-, *, +, 1. , 1) ).
    let line = LIST_MARKER.replace(&line, "").into_owned();

    strip_inline_formatting(&line)
}

// MARK: - Inline

static IMAGE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"!\[[^\]]*\]\([^)]*\)").unwrap());
static LINK: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\[([^\]]+)\]\([^)]*\)").unwrap());
static REF_LINK: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\[([^\]]+)\]\[[^\]]*\]").unwrap());
static INLINE_CODE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"`+([^`]+)`+").unwrap());
static BOLD_ITALIC_STAR: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\*\*\*([^*]+)\*\*\*").unwrap());
static BOLD_ITALIC_UNDER: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"___([^_]+)___").unwrap());
static BOLD_STAR: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\*\*([^*]+)\*\*").unwrap());
static BOLD_UNDER: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"__([^_]+)__").unwrap());
static ITALIC_STAR: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?<!\w)\*([^*]+)\*(?!\w)").unwrap());
static ITALIC_UNDER: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?<!\w)_([^_]+)_(?!\w)").unwrap());
static STRIKETHROUGH: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"~~([^~]+)~~").unwrap());
static INNER_WHITESPACE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[ \t]+").unwrap());

/// Remove markdown emphasis, code, links, and images while preserving the
/// readable text. Order matters: longest emphasis markers first, or `**bold**`
/// would be eaten a star at a time.
fn strip_inline_formatting(s: &str) -> String {
    // Images ![alt](url) -> drop entirely (we don't read alt by default).
    let text = IMAGE.replace_all(s, "");
    // Links [text](url) -> text
    let text = LINK.replace_all(&text, "$1").into_owned();
    // Reference-style links [text][ref] -> text
    let text = REF_LINK.replace_all(&text, "$1").into_owned();
    // Strip inline code backticks but keep the content. Handle 1+ backticks.
    let text = INLINE_CODE.replace_all(&text, "$1").into_owned();

    let text = BOLD_ITALIC_STAR.replace_all(&text, "$1").into_owned();
    let text = BOLD_ITALIC_UNDER.replace_all(&text, "$1").into_owned();
    let text = BOLD_STAR.replace_all(&text, "$1").into_owned();
    let text = BOLD_UNDER.replace_all(&text, "$1").into_owned();
    let text = ITALIC_STAR.replace_all(&text, "$1").into_owned();
    let text = ITALIC_UNDER.replace_all(&text, "$1").into_owned();

    // Strikethrough ~~text~~ -> text
    let text = STRIKETHROUGH.replace_all(&text, "$1").into_owned();

    // Collapse repeated internal whitespace.
    let text = INNER_WHITESPACE.replace_all(&text, " ").into_owned();

    text.trim_matches(|c: char| c == ' ' || c == '\t')
        .to_string()
}

// MARK: - Whitespace

fn collapse_blank_runs(lines: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut last_was_blank = false;
    for line in lines {
        let blank = line
            .trim_matches(|c: char| c == ' ' || c == '\t')
            .is_empty();
        if blank {
            if !last_was_blank && !out.is_empty() {
                out.push(String::new());
            }
            last_was_blank = true;
        } else {
            out.push(line.clone());
            last_was_blank = false;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    // Mirrors `YapperTests/TextCleanerTests.swift` case-for-case. TextCleaner is
    // the layer between "what the copy button captured" and "what gets spoken";
    // regressions here are silent in daily use — the app keeps working, it just
    // reads garbage — so every markdown rule the spec cares about is pinned.

    // MARK: - Fenced code (spec: silently skipped, no announcement)

    #[test]
    fn strips_fenced_code_blocks() {
        let input = "Before.\n```swift\nlet x = 1\nprint(x)\n```\nAfter.";
        assert_eq!(clean(input), "Before.\nAfter.");
    }

    #[test]
    fn strips_tilde_fences() {
        assert_eq!(
            clean("Before.\n~~~\ncode here\n~~~\nAfter."),
            "Before.\nAfter."
        );
    }

    #[test]
    fn unclosed_fence_drops_rest_of_text() {
        assert_eq!(clean("Kept.\n```\nnever closed\nstill code"), "Kept.");
    }

    #[test]
    fn backtick_fence_inside_tilde_fence_stays_code() {
        let input = "Before.\n~~~\n```\ninner\n```\n~~~\nAfter.";
        assert_eq!(clean(input), "Before.\nAfter.");
    }

    #[test]
    fn code_only_response_cleans_to_empty() {
        assert!(clean("```python\nprint('hi')\n```").is_empty());
    }

    // MARK: - Block markers

    #[test]
    fn strips_heading_markers() {
        assert_eq!(clean("## The Plan"), "The Plan");
        assert_eq!(clean("###### Deep heading"), "Deep heading");
    }

    #[test]
    fn strips_list_markers() {
        assert_eq!(clean("- dash item"), "dash item");
        assert_eq!(clean("* star item"), "star item");
        assert_eq!(clean("+ plus item"), "plus item");
        assert_eq!(clean("1. numbered"), "numbered");
        assert_eq!(clean("2) parens"), "parens");
    }

    #[test]
    fn strips_blockquote_markers() {
        assert_eq!(clean("> quoted text"), "quoted text");
    }

    #[test]
    fn drops_horizontal_rules() {
        assert_eq!(clean("para one\n---\npara two"), "para one\n\npara two");
        assert_eq!(clean("para one\n***\npara two"), "para one\n\npara two");
    }

    #[test]
    fn drops_table_rows() {
        let input = "Intro.\n| a | b |\n|---|---|\n| 1 | 2 |\nAfter.";
        assert_eq!(clean(input), "Intro.\n\nAfter.");
    }

    // MARK: - Inline formatting

    #[test]
    fn keeps_link_text_drops_url() {
        assert_eq!(
            clean("see [the docs](https://example.com/x) now"),
            "see the docs now"
        );
        assert_eq!(clean("ref [style][1] link"), "ref style link");
    }

    #[test]
    fn drops_images_entirely() {
        assert_eq!(clean("before ![alt text](img.png) after"), "before after");
    }

    #[test]
    fn keeps_inline_code_content() {
        assert_eq!(
            clean("run `swift build` locally"),
            "run swift build locally"
        );
    }

    #[test]
    fn strips_emphasis_markers() {
        assert_eq!(clean("***a*** **b** *c* __d__ _e_ ~~f~~"), "a b c d e f");
    }

    #[test]
    fn keeps_asterisks_inside_words() {
        // (?<!\w) guards: 2*3*4 is arithmetic, not emphasis.
        assert_eq!(clean("compute 2*3*4 now"), "compute 2*3*4 now");
    }

    // MARK: - Whitespace / pauses

    #[test]
    fn collapses_blank_runs_to_single_paragraph_break() {
        assert_eq!(clean("one\n\n\n\ntwo"), "one\n\ntwo");
    }

    #[test]
    fn keeps_paragraph_break_after_heading() {
        // The blank line is the TTS pause per spec — it must survive cleaning.
        assert_eq!(clean("## Title\n\nBody text."), "Title\n\nBody text.");
    }

    #[test]
    fn collapses_internal_whitespace() {
        assert_eq!(clean("too    many\tspaces"), "too many spaces");
    }

    #[test]
    fn empty_input_cleans_to_empty() {
        assert!(clean("").is_empty());
        assert!(clean("   \n\n  ").is_empty());
    }
}
