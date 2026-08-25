//! The scheduling half of `Yapper/Services/SentenceStreamPlayer.swift`, with no
//! audio device attached.
//!
//! The Swift player interleaves two concerns: *what to synthesize and where the
//! playhead is* (arithmetic over segments) and *making sound come out*
//! (`AVAudioPlayer`). This module is the first half on its own — deterministic,
//! synchronous, and testable on any OS, which is what lets the parity tests in
//! `YapperTests/TranscriptTests.swift` have a Rust counterpart that runs in CI
//! with no speakers. `player.rs` bolts the audio half on top.
//!
//! Divergence note vs the Swift original: character counts are Unicode scalars
//! (`chars()`) where Swift counts grapheme clusters. Identical for ASCII, and at
//! the scale these feed (duration estimates, transcript apportioning) the
//! difference is inaudible.

use super::segmentation;

/// Rough chars→seconds factor for estimating total duration before real
/// durations are known.
pub const SECONDS_PER_CHAR: f64 = 0.060;

#[derive(Clone, Debug, Default)]
pub struct Segment {
    pub text: String,
    pub data: Option<Vec<u8>>,
    pub duration: Option<f64>,
    pub failed: bool,
    /// The API's `request-id` for this segment's audio — lets a later segment
    /// stitch to it even when synthesis ran out of order after a scrub jump.
    pub request_id: Option<String>,
}

impl Segment {
    pub fn new(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            ..Default::default()
        }
    }
}

/// One clickable line of the transcript.
#[derive(Clone, Debug, PartialEq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptLine {
    pub id: usize,
    pub text: String,
    pub start: f64,
    pub end: f64,
    /// This line's audio exists — clicking it plays instantly. Otherwise the
    /// deck parks there and the pipeline synthesizes it next.
    pub is_loaded: bool,
    /// Its segment failed to synthesize; it will never be spoken.
    pub is_failed: bool,
}

impl TranscriptLine {
    pub fn contains(&self, t: f64) -> bool {
        t >= self.start && t < self.end
    }
}

/// Where a seek landed. `offset` is the intra-segment position; when the target
/// segment has no audio yet the caller parks the transport and holds `offset` as
/// the pending entry point (the Swift `pendingSeekOffset`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SeekTarget {
    pub index: usize,
    /// Summed span of every segment before `index` — the Swift `baseTime`.
    pub base_time: f64,
    pub offset: f64,
}

#[derive(Debug, Default)]
pub struct Timeline {
    pub segments: Vec<Segment>,
    pub current_index: usize,
    pub base_time: f64,
    pub pending_seek_offset: Option<f64>,
}

impl Timeline {
    pub fn new(sentences: Vec<String>) -> Self {
        Self {
            segments: sentences.into_iter().map(Segment::new).collect(),
            ..Default::default()
        }
    }

    /// Replay construction: a single, already-complete clip. `text` never
    /// affects playback, it just gives the transcript something to show.
    pub fn replay(text: String, data: Vec<u8>) -> Self {
        Self {
            segments: vec![Segment {
                text,
                data: Some(data),
                ..Default::default()
            }],
            ..Default::default()
        }
    }

    // MARK: - Duration

    /// Chars→seconds rate observed from the segments that already have real
    /// audio; falls back to the rough constant until the first segment lands.
    /// Using the voice's *measured* pace makes the estimated total converge on
    /// the true duration early instead of jumping at the end.
    pub fn measured_seconds_per_char(&self) -> f64 {
        let mut seconds = 0.0;
        let mut chars = 0usize;
        for seg in &self.segments {
            if let Some(d) = seg.duration {
                if !seg.text.is_empty() {
                    seconds += d;
                    chars += seg.text.chars().count();
                }
            }
        }
        if chars == 0 || seconds <= 0.0 {
            SECONDS_PER_CHAR
        } else {
            seconds / chars as f64
        }
    }

    /// How much timeline a segment occupies. Failed segments are zero-length:
    /// they're excluded from the scrubber's scale, and landing on one would park
    /// the transport forever because no audio is coming.
    fn span(&self, i: usize, per_char: f64) -> f64 {
        let seg = &self.segments[i];
        if seg.failed {
            0.0
        } else {
            seg.duration
                .unwrap_or_else(|| seg.text.chars().count() as f64 * per_char)
        }
    }

    pub fn total_duration(&self) -> f64 {
        let per_char = self.measured_seconds_per_char();
        let sum: f64 = (0..self.segments.len())
            .map(|i| self.span(i, per_char))
            .sum();
        sum.max(0.1)
    }

    // MARK: - Transcript

    /// Rebuild the transcript on the same walk `seek_target` uses, so a line's
    /// `start` is exactly the time that seeks into it. Each segment's span is
    /// divided among its sentences by character count; the last sentence absorbs
    /// the rounding so lines stay contiguous.
    pub fn transcript(&self) -> Vec<TranscriptLine> {
        let per_char = self.measured_seconds_per_char();
        let mut lines: Vec<TranscriptLine> = Vec::new();
        let mut acc = 0.0;
        for (i, seg) in self.segments.iter().enumerate() {
            let span = self.span(i, per_char);
            let sentences = segmentation::sentences(&seg.text);
            let chars = sentences
                .iter()
                .map(|s| s.chars().count())
                .sum::<usize>()
                .max(1);
            let mut offset = 0.0;
            let count = sentences.len();
            for (k, s) in sentences.into_iter().enumerate() {
                let is_last = k == count - 1;
                let start = acc + offset;
                offset += span * s.chars().count() as f64 / chars as f64;
                lines.push(TranscriptLine {
                    id: lines.len(),
                    text: s,
                    start,
                    end: if is_last {
                        acc + span
                    } else {
                        (acc + offset).max(start)
                    },
                    is_loaded: seg.data.is_some(),
                    is_failed: seg.failed,
                });
            }
            acc += span;
        }
        lines
    }

    /// Merge the synthesized segments into contiguous timeline ranges, on the
    /// same walk `seek_target` uses. Failed segments are zero-length there, so
    /// they can't split a run.
    pub fn buffered_ranges(&self) -> Vec<(f64, f64)> {
        let per_char = self.measured_seconds_per_char();
        let mut ranges = Vec::new();
        let mut acc = 0.0;
        let mut run_start: Option<f64> = None;
        for (i, seg) in self.segments.iter().enumerate() {
            let buffered = seg.data.is_some() || seg.failed;
            if buffered && run_start.is_none() {
                run_start = Some(acc);
            }
            if !buffered {
                if let Some(start) = run_start.take() {
                    if acc > start {
                        ranges.push((start, acc));
                    }
                }
            }
            acc += self.span(i, per_char);
        }
        if let Some(start) = run_start {
            if acc > start {
                ranges.push((start, acc));
            }
        }
        ranges
    }

    // MARK: - Synthesis order

    /// The next segment the pipeline should synthesize, re-decided after every
    /// request so a scrub can redirect it mid-read:
    /// 1. whatever the playhead is sitting on (a scrub parked there, or playback
    ///    caught up), then onward from the playhead — audio the user is about to
    ///    hear always wins,
    /// 2. else the earliest gap left behind by forward jumps — playback never
    ///    revisits it, but the History cache needs every segment.
    ///
    /// Before scrubs could jump the playhead this was a plain `0..count` walk;
    /// sequential order made forward scrubs wait for every intervening segment
    /// on the slow models.
    pub fn next_synth_index(&self) -> Option<usize> {
        let needs = |s: &Segment| s.data.is_none() && !s.failed;
        let head = self.current_index.min(self.segments.len());
        (head..self.segments.len())
            .find(|&i| needs(&self.segments[i]))
            .or_else(|| (0..head).find(|&i| needs(&self.segments[i])))
    }

    /// Ids of the contiguous already-synthesized run ending just before `i`
    /// (oldest → newest, capped at the API's limit of 3). Stitching survives
    /// out-of-order synthesis: a segment stitches to its real predecessors when
    /// their audio exists, and falls back to `previous_text` conditioning when
    /// the user jumped into unsynthesized territory.
    pub fn stitch_ids(&self, before: usize) -> Vec<String> {
        let mut ids = Vec::new();
        let mut j = before;
        while j > 0 && ids.len() < 3 {
            j -= 1;
            let seg = &self.segments[j];
            match (&seg.data, &seg.request_id) {
                (Some(_), Some(id)) => ids.push(id.clone()),
                _ => break,
            }
        }
        ids.reverse();
        ids
    }

    // MARK: - Seeking

    /// Resolve a scrub position to a segment and an intra-segment offset,
    /// walking the same scale `total_duration` publishes. `None` only when there
    /// are no segments at all.
    pub fn seek_target(&self, seconds: f64) -> Option<SeekTarget> {
        if self.segments.is_empty() {
            return None;
        }
        let target = seconds.clamp(0.0, self.total_duration());
        let per_char = self.measured_seconds_per_char();
        let mut acc = 0.0;
        for i in 0..self.segments.len() {
            let d = self.span(i, per_char);
            let is_last = i == self.segments.len() - 1;
            if target < acc + d || is_last {
                return Some(SeekTarget {
                    index: i,
                    base_time: acc,
                    offset: (target - acc).max(0.0),
                });
            }
            acc += d;
        }
        None
    }

    // MARK: - Cache

    /// Every segment's audio made it in. A clip with silent holes (a mid-stream
    /// synth failure) is worse than re-synthesizing on replay, so the cache is
    /// published only when this holds.
    pub fn is_complete(&self) -> bool {
        !self.segments.is_empty() && self.segments.iter().all(|s| s.data.is_some())
    }

    /// The whole read as one clip, in segment order — correct even when scrub
    /// jumps made synthesis run out of order.
    pub fn assembled_audio(&self) -> Vec<u8> {
        let mut whole = Vec::new();
        for seg in &self.segments {
            if let Some(d) = &seg.data {
                whole.extend_from_slice(d);
            }
        }
        whole
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn timeline(text: &str) -> Timeline {
        Timeline::new(segmentation::segments(text))
    }

    // ── Mirrors YapperTests/TranscriptTests.swift ───────────────────────────
    // The transcript is what the liner-notes panel clicks into seeks with, so
    // its lines have to walk the same timeline `seek_target` walks: contiguous,
    // in order, ending exactly at total_duration. These run on the pre-audio
    // estimates (no network, no synthesis) — the same state the panel is in for
    // the first few seconds of every read.

    #[test]
    fn one_line_per_sentence_in_reading_order() {
        let t = timeline("First one. Second one. Third one.");
        assert_eq!(
            t.transcript()
                .iter()
                .map(|l| l.text.as_str())
                .collect::<Vec<_>>(),
            ["First one.", "Second one.", "Third one."]
        );
    }

    #[test]
    fn lines_are_contiguous_and_span_the_whole_timeline() {
        let t = timeline("Alpha beta gamma. Delta epsilon zeta. Eta theta iota. Kappa lambda mu.");
        let lines = t.transcript();
        assert_eq!(lines.len(), 4, "got: {lines:#?}");

        assert_eq!(lines[0].start, 0.0);
        for (a, b) in lines.iter().zip(lines.iter().skip(1)) {
            assert!(a.end <= b.start + 1e-9, "lines overlap");
            assert!((b.start - a.end).abs() < 1e-6, "hole between lines");
        }
        assert!((lines.last().unwrap().end - t.total_duration()).abs() < 1e-6);
    }

    #[test]
    fn longer_sentences_get_longer_spans() {
        let t = timeline("Hi. This sentence is considerably longer than the one before it.");
        let lines = t.transcript();
        assert_eq!(lines.len(), 2, "got: {lines:#?}");
        assert!((lines[1].end - lines[1].start) > (lines[0].end - lines[0].start));
    }

    #[test]
    fn nothing_is_loaded_before_synthesis_runs() {
        let t = timeline("One. Two.");
        assert!(t.transcript().iter().all(|l| !l.is_loaded && !l.is_failed));
    }

    #[test]
    fn empty_text_has_no_transcript() {
        assert!(timeline("   \n ").transcript().is_empty());
    }

    // ── Rust-side only ─────────────────────────────────────────────────────
    // The Swift player has no unit tests for scrub-driven synthesis ordering,
    // stitching, or cache completeness — that logic is welded to AVAudioPlayer
    // and @MainActor there. Extracting it here makes it testable, so these pin
    // behavior the Swift side currently only asserts through code comments.
    // Treat them as the contract to hold the Swift side to, not as a mirror.

    fn synthesized(t: &mut Timeline, i: usize, id: &str, duration: f64) {
        t.segments[i].data = Some(vec![0u8; 16]);
        t.segments[i].request_id = Some(id.to_string());
        t.segments[i].duration = Some(duration);
    }

    #[test]
    fn synthesis_starts_at_the_playhead_and_walks_forward() {
        let mut t = Timeline::new(vec!["a".into(), "b".into(), "c".into()]);
        assert_eq!(t.next_synth_index(), Some(0));
        synthesized(&mut t, 0, "r0", 1.0);
        assert_eq!(t.next_synth_index(), Some(1));
    }

    /// A forward scrub parks the playhead ahead of the buffer; the very next
    /// request must be the segment the user is waiting on, not the gap behind.
    #[test]
    fn a_forward_scrub_redirects_the_next_request_to_the_playhead() {
        let mut t = Timeline::new(vec!["a".into(), "b".into(), "c".into(), "d".into()]);
        synthesized(&mut t, 0, "r0", 1.0);
        t.current_index = 2;
        assert_eq!(t.next_synth_index(), Some(2));
    }

    /// Once the playhead's stretch is covered, the pipeline goes back for the
    /// gap the jump left behind — playback never revisits it, but the History
    /// cache needs every segment.
    #[test]
    fn gaps_behind_the_playhead_are_backfilled_last() {
        let mut t = Timeline::new(vec!["a".into(), "b".into(), "c".into()]);
        synthesized(&mut t, 0, "r0", 1.0);
        t.current_index = 2;
        synthesized(&mut t, 2, "r2", 1.0);
        assert_eq!(t.next_synth_index(), Some(1));
    }

    #[test]
    fn failed_segments_are_never_retried() {
        let mut t = Timeline::new(vec!["a".into(), "b".into()]);
        t.segments[0].failed = true;
        assert_eq!(t.next_synth_index(), Some(1));
        t.segments[1].failed = true;
        assert_eq!(t.next_synth_index(), None);
    }

    #[test]
    fn stitching_takes_the_last_three_contiguous_predecessors() {
        let mut t = Timeline::new((0..6).map(|i| format!("s{i}")).collect());
        for i in 0..5 {
            synthesized(&mut t, i, &format!("r{i}"), 1.0);
        }
        assert_eq!(t.stitch_ids(5), vec!["r2", "r3", "r4"]);
        assert!(t.stitch_ids(0).is_empty());
    }

    /// A jump into unsynthesized territory leaves a hole behind the playhead.
    /// Stitching stops at that hole rather than splicing onto audio that isn't
    /// adjacent — the segment falls back to `previous_text` conditioning.
    #[test]
    fn stitching_stops_at_an_unsynthesized_hole() {
        let mut t = Timeline::new((0..4).map(|i| format!("s{i}")).collect());
        synthesized(&mut t, 0, "r0", 1.0);
        synthesized(&mut t, 2, "r2", 1.0);
        assert_eq!(t.stitch_ids(3), vec!["r2"]);
    }

    #[test]
    fn seeks_land_where_the_transcript_says_they_will() {
        let t = timeline("Alpha beta gamma. Delta epsilon zeta. Eta theta iota.");
        for line in t.transcript() {
            let target = t.seek_target(line.start).expect("segments exist");
            let landed = target.base_time + target.offset;
            assert!(
                (landed - line.start).abs() < 1e-6,
                "line {} starts at {} but seeking there landed at {landed}",
                line.id,
                line.start
            );
        }
    }

    #[test]
    fn seeks_clamp_to_the_timeline() {
        let t = timeline("One. Two. Three.");
        let start = t.seek_target(-50.0).unwrap();
        assert_eq!((start.index, start.base_time, start.offset), (0, 0.0, 0.0));

        let end = t.seek_target(1e6).unwrap();
        assert_eq!(end.index, t.segments.len() - 1);
        assert!((end.base_time + end.offset - t.total_duration()).abs() < 1e-6);
    }

    #[test]
    fn buffered_ranges_merge_adjacent_synthesized_segments() {
        let mut t = Timeline::new(vec!["a".into(), "b".into(), "c".into(), "d".into()]);
        synthesized(&mut t, 0, "r0", 1.0);
        synthesized(&mut t, 1, "r1", 1.0);
        synthesized(&mut t, 3, "r3", 1.0);
        let ranges = t.buffered_ranges();
        assert_eq!(ranges.len(), 2, "got: {ranges:#?}");
        assert_eq!(ranges[0].0, 0.0);
        assert!((ranges[0].1 - 2.0).abs() < 1e-9);
    }

    #[test]
    fn the_cache_is_only_complete_when_every_segment_landed() {
        let mut t = Timeline::new(vec!["a".into(), "b".into()]);
        synthesized(&mut t, 0, "r0", 1.0);
        assert!(!t.is_complete(), "a half-synthesized read must not publish");
        // A failed segment is a hole, not a completion.
        t.segments[1].failed = true;
        assert!(!t.is_complete());
        synthesized(&mut t, 1, "r1", 1.0);
        assert!(t.is_complete());
    }

    #[test]
    fn assembled_audio_is_in_segment_order_regardless_of_synthesis_order() {
        let mut t = Timeline::new(vec!["a".into(), "b".into()]);
        t.segments[1].data = Some(b"second".to_vec());
        t.segments[0].data = Some(b"first".to_vec());
        assert_eq!(t.assembled_audio(), b"firstsecond".to_vec());
    }

    /// Real durations replace the rough constant as they land, so the estimate
    /// converges instead of jumping when the last segment arrives.
    #[test]
    fn measured_pace_replaces_the_estimate_once_audio_lands() {
        let mut t = Timeline::new(vec!["aaaaaaaaaa".into(), "aaaaaaaaaa".into()]);
        assert!((t.total_duration() - 20.0 * SECONDS_PER_CHAR).abs() < 1e-9);
        synthesized(&mut t, 0, "r0", 5.0); // 10 chars → 0.5 s/char measured
        assert!((t.measured_seconds_per_char() - 0.5).abs() < 1e-9);
        assert!((t.total_duration() - 10.0).abs() < 1e-9);
    }
}
