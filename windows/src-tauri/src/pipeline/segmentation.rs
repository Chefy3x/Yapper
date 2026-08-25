//! Sentence segmentation — port of `SentenceStreamPlayer.segments(from:)`
//! (`Yapper/Services/SentenceStreamPlayer.swift`).
//!
//! Split text into playback segments: the first sentence alone (fast
//! time-to-first-audio), then progressively larger sentence batches. Fewer,
//! bigger requests plus request stitching keep the read sounding like one take.
//!
//! Divergence notes vs the Swift original:
//! - Sentence boundaries come from ICU4X (UAX #29 rules) instead of Apple's
//!   `.bySentences` linguistic tokenizer. Both need sentence-like cues (e.g. an
//!   uppercase letter after a period) to split, but edge cases can differ; the
//!   golden tests below pin the cases we care about.
//! - Batch caps count Unicode scalars (`chars()`), Swift counts grapheme
//!   clusters. Identical for ASCII; off-by-a-few for emoji-dense text, which is
//!   irrelevant at cap scale.

use icu_segmenter::SentenceSegmenter;

/// Batch caps by position: the first sentence rides alone, the second batch
/// stays small so it's synthesized before the short opener finishes playing,
/// and everything after ships in big batches. Mirrors the Swift constants.
const SECOND_BATCH_CAP: usize = 350;
const BATCH_CAP: usize = 1_000;

/// Sentence split shared by segmentation and the transcript, so every transcript
/// line is a whole sentence of exactly the text that was sent for synthesis.
/// Port of `SentenceStreamPlayer.sentences(in:)`: empty in, empty out; text the
/// segmenter refuses to split comes back as one sentence.
pub fn sentences(text: &str) -> Vec<String> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }
    let out = split_sentences(trimmed);
    if out.is_empty() {
        vec![trimmed.to_string()]
    } else {
        out
    }
}

pub fn segments(text: &str) -> Vec<String> {
    let sentences = sentences(text);
    if sentences.is_empty() {
        return Vec::new();
    }

    let mut result = vec![sentences[0].clone()];
    let mut buffer = String::new();
    for s in &sentences[1..] {
        let cap = if result.len() == 1 {
            SECOND_BATCH_CAP
        } else {
            BATCH_CAP
        };
        if buffer.is_empty() {
            buffer = s.clone();
        // The + 1 is the space that will join them, not an off-by-one.
        } else if buffer.chars().count() + 1 + s.chars().count() <= cap {
            buffer.push(' ');
            buffer.push_str(s);
        } else {
            result.push(std::mem::take(&mut buffer));
            buffer = s.clone();
        }
    }
    if !buffer.is_empty() {
        result.push(buffer);
    }
    result
}

/// ICU4X sentence boundaries → trimmed, non-empty sentence strings.
/// Robust to whether the break iterator yields the leading 0 / trailing len.
fn split_sentences(text: &str) -> Vec<String> {
    let segmenter = SentenceSegmenter::new();
    let mut out = Vec::new();
    let mut prev = 0usize;
    for brk in segmenter.segment_str(text) {
        if brk == 0 || brk == prev {
            continue;
        }
        let s = text[prev..brk].trim();
        if !s.is_empty() {
            out.push(s.to_string());
        }
        prev = brk;
    }
    if prev < text.len() {
        let s = text[prev..].trim();
        if !s.is_empty() {
            out.push(s.to_string());
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A 100-char sentence with an uppercase opener, so both Apple's tokenizer
    /// and ICU treat consecutive copies as separate sentences.
    fn sentence100() -> String {
        format!("A{}.", "a".repeat(98))
    }

    #[test]
    fn empty_input_is_empty() {
        assert!(segments("  \n ").is_empty());
    }

    #[test]
    fn first_sentence_rides_alone() {
        let segs = segments("Alpha beta. Gamma delta. Epsilon zeta.");
        assert_eq!(
            segs,
            vec![
                "Alpha beta.".to_string(),
                "Gamma delta. Epsilon zeta.".to_string()
            ]
        );
    }

    /// Mirrors `YapperTests/SegmentationTests.swift` (current 350-cap behavior):
    /// five 100-char sentences → [s1, s2+s3+s4 (302 ≤ 350), s5].
    #[test]
    fn second_batch_caps_at_350() {
        let s = sentence100();
        let text = vec![s.clone(); 5].join(" ");
        let segs = segments(&text);
        assert_eq!(segs.len(), 3, "got: {segs:#?}");
        assert_eq!(segs[0], s);
        assert_eq!(segs[1], format!("{s} {s} {s}"));
        assert_eq!(segs[2], s);
    }

    /// Mirrors `noContentIsLostAcrossSegmentation` in the Swift tests.
    #[test]
    fn no_content_lost() {
        let text = "Alpha beta. Gamma delta. Epsilon zeta. Eta theta.";
        assert_eq!(segments(text).join(" "), text);
    }
}
