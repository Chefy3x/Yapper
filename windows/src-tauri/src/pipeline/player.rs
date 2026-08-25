//! The transport half of `Yapper/Services/SentenceStreamPlayer.swift`.
//!
//! Plays a piece of text as a sequence of segments: the first sentence alone,
//! then progressively larger batches. The first segment starts playing as soon
//! as it's synthesized while the rest are fetched in the background — so
//! time-to-first-audio is ~one short sentence instead of the whole response.
//! Each request is stitched to the previous ones' audio (`previous_request_ids`)
//! so the delivery flows like a single take.
//!
//! All the arithmetic — synthesis order, seek resolution, transcript, buffered
//! ranges — lives in [`Timeline`]. This module owns the parts that touch the
//! world: an [`AudioSink`], a synthesis task, and the cache file.
//!
//! Structural divergence from the Swift original: `AVAudioPlayer` reports a
//! finished segment through a delegate callback, while here the driver polls
//! [`StreamPlayer::tick`] (~10 Hz, the same cadence as the Swift `Timer` that
//! moves the scrubber). One clock instead of two, and it makes the seam logic
//! steppable in tests.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::Serialize;

use super::synthesizer::{SpeechSynthesizing, SynthesisRequest};
use super::timeline::{Timeline, TranscriptLine};
use crate::audio::{decode, AudioSink, DecodedAudio};

pub const AVAILABLE_RATES: [f32; 5] = [1.0, 1.25, 1.5, 1.75, 2.0];

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "state", content = "message", rename_all = "camelCase")]
pub enum PlayerState {
    Idle,
    BufferingFirstAudio,
    Playing,
    Paused,
    Finished,
    Failed(String),
}

/// Everything the deck renders, in one lock-free-to-the-caller read.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    #[serde(flatten)]
    pub state: PlayerState,
    pub current_time: f64,
    pub total_duration: f64,
    pub rate: f32,
    /// Stretches of the timeline whose audio is already synthesized — a scrub
    /// landing inside one plays instantly; outside, playback buffers until that
    /// segment is generated.
    pub buffered_ranges: Vec<(f64, f64)>,
    pub transcript: Vec<TranscriptLine>,
    /// Index of the line the playhead is inside, so the deck highlights the same
    /// line the ported timeline says is playing instead of re-deriving it in JS.
    pub active_line: Option<usize>,
}

type Callback = Box<dyn Fn() + Send + Sync>;

struct Inner {
    timeline: Timeline,
    decoded: HashMap<usize, DecodedAudio>,
    state: PlayerState,
    current_time: f64,
    rate: f32,
}

pub struct StreamPlayer {
    inner: Mutex<Inner>,
    sink: Arc<dyn AudioSink>,
    synthesizer: Option<Arc<dyn SpeechSynthesizing>>,
    cache_path: PathBuf,
    is_replay: bool,
    cancelled: AtomicBool,
    on_finish: Mutex<Option<Callback>>,
    on_failure: Mutex<Option<Callback>>,
}

impl StreamPlayer {
    /// Live synthesis.
    pub fn new(
        sentences: Vec<String>,
        synthesizer: Arc<dyn SpeechSynthesizing>,
        sink: Arc<dyn AudioSink>,
        cache_path: PathBuf,
    ) -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(Inner {
                timeline: Timeline::new(sentences),
                decoded: HashMap::new(),
                state: PlayerState::Idle,
                current_time: 0.0,
                rate: 1.0,
            }),
            sink,
            synthesizer: Some(synthesizer),
            cache_path,
            is_replay: false,
            cancelled: AtomicBool::new(false),
            on_finish: Mutex::new(None),
            on_failure: Mutex::new(None),
        })
    }

    /// Replay — a single, already-complete clip on disk. No synthesis. `text` is
    /// the read's original text: it never affects playback, it just gives the
    /// transcript something to show.
    pub fn replay(
        existing_file: &Path,
        text: String,
        sink: Arc<dyn AudioSink>,
    ) -> std::io::Result<Arc<Self>> {
        let data = std::fs::read(existing_file)?;
        Ok(Arc::new(Self {
            inner: Mutex::new(Inner {
                timeline: Timeline::replay(text, data),
                decoded: HashMap::new(),
                state: PlayerState::Idle,
                current_time: 0.0,
                rate: 1.0,
            }),
            sink,
            synthesizer: None,
            cache_path: existing_file.to_path_buf(),
            is_replay: true,
            cancelled: AtomicBool::new(false),
            on_finish: Mutex::new(None),
            on_failure: Mutex::new(None),
        }))
    }

    pub fn set_on_finish(&self, f: Callback) {
        *self.on_finish.lock().unwrap() = Some(f);
    }

    /// Called when no audio could be produced at all (e.g. the first segment
    /// failed to synthesize), so the coordinator can fall back to the native
    /// voice.
    pub fn set_on_failure(&self, f: Callback) {
        *self.on_failure.lock().unwrap() = Some(f);
    }

    // MARK: - Snapshot

    pub fn snapshot(&self) -> Snapshot {
        let inner = self.inner.lock().unwrap();
        let transcript = inner.timeline.transcript();
        let active_line = transcript
            .iter()
            .position(|l| l.contains(inner.current_time));
        Snapshot {
            state: inner.state.clone(),
            current_time: inner.current_time,
            total_duration: inner.timeline.total_duration(),
            rate: inner.rate,
            buffered_ranges: inner.timeline.buffered_ranges(),
            transcript,
            active_line,
        }
    }

    pub fn state(&self) -> PlayerState {
        self.inner.lock().unwrap().state.clone()
    }

    pub fn is_active(&self) -> bool {
        matches!(
            self.state(),
            PlayerState::Playing | PlayerState::BufferingFirstAudio
        )
    }

    // MARK: - Control

    pub fn start(self: &Arc<Self>) {
        self.inner.lock().unwrap().state = PlayerState::BufferingFirstAudio;
        if !self.is_replay {
            self.launch_synth_pipeline();
        }
        // Replay starts now; live stays buffering until segment 0 lands.
        self.play_current();
    }

    pub fn pause(&self) {
        let mut inner = self.inner.lock().unwrap();
        if inner.state != PlayerState::Playing {
            return;
        }
        self.sink.pause();
        inner.state = PlayerState::Paused;
    }

    pub fn resume(&self) {
        let mut inner = self.inner.lock().unwrap();
        let i = inner.timeline.current_index;
        if i >= inner.timeline.segments.len() {
            return;
        }
        Self::ensure_decoded(&mut inner, i);
        let Some(audio) = inner.decoded.get(&i).cloned() else {
            inner.state = PlayerState::BufferingFirstAudio;
            return;
        };
        // A forward scrub may have parked us mid-segment before its audio
        // existed — start there rather than resuming a source that isn't loaded.
        if let Some(off) = inner.timeline.pending_seek_offset.take() {
            let clamped = off.clamp(0.0, audio.duration());
            let _ = self.sink.play(&audio, Duration::from_secs_f64(clamped));
            inner.current_time = inner.timeline.base_time + clamped;
        } else {
            self.sink.resume();
        }
        inner.state = PlayerState::Playing;
    }

    pub fn stop(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
        self.sink.stop();
        let mut inner = self.inner.lock().unwrap();
        inner.decoded.clear();
        inner.timeline.pending_seek_offset = None;
        inner.state = PlayerState::Idle;
        drop(inner);
        // Interrupted synthesis — never publish a truncated clip.
        self.discard_part_file();
    }

    pub fn set_rate(&self, new_rate: f32) {
        let clamped = new_rate.clamp(
            AVAILABLE_RATES[0],
            AVAILABLE_RATES[AVAILABLE_RATES.len() - 1],
        );
        self.inner.lock().unwrap().rate = clamped;
        self.sink.set_rate(clamped);
    }

    pub fn cycle_rate(&self) {
        let rate = self.inner.lock().unwrap().rate;
        let idx = AVAILABLE_RATES.iter().position(|r| *r == rate).unwrap_or(0);
        self.set_rate(AVAILABLE_RATES[(idx + 1) % AVAILABLE_RATES.len()]);
    }

    /// Step to the adjacent rate (clamped at the ends) — the deck's REW/FF
    /// speed controls.
    pub fn step_rate(&self, up: bool) {
        let rate = self.inner.lock().unwrap().rate;
        let idx = AVAILABLE_RATES
            .iter()
            .position(|r| *r == rate)
            .unwrap_or_else(|| {
                AVAILABLE_RATES
                    .iter()
                    .enumerate()
                    .min_by(|a, b| (a.1 - rate).abs().partial_cmp(&(b.1 - rate).abs()).unwrap())
                    .map(|(i, _)| i)
                    .unwrap_or(0)
            });
        let next = if up {
            (idx + 1).min(AVAILABLE_RATES.len() - 1)
        } else {
            idx.saturating_sub(1)
        };
        self.set_rate(AVAILABLE_RATES[next]);
    }

    pub fn seek(&self, seconds: f64) {
        let mut inner = self.inner.lock().unwrap();
        let Some(target) = inner.timeline.seek_target(seconds) else {
            return;
        };
        // Whether audio was being produced before the scrub — decides if
        // playback should resume automatically once the target segment lands.
        let was_active = matches!(
            inner.state,
            PlayerState::Playing | PlayerState::BufferingFirstAudio
        );
        if inner.timeline.current_index != target.index {
            self.sink.stop();
        }
        inner.timeline.current_index = target.index;
        inner.timeline.base_time = target.base_time;

        Self::ensure_decoded(&mut inner, target.index);
        let Some(audio) = inner.decoded.get(&target.index).cloned() else {
            // Scrubbing ahead of the synthesized buffer. Park the transport on
            // this segment and hold the needle where the user dropped it — the
            // pipeline synthesizes it NEXT (see `Timeline::next_synth_index`)
            // and its landing resumes playback here; a manual resume honors the
            // same pending offset.
            log::debug!(
                "Seek {seconds:.1}s → parked on unsynthesized segment {}, waiting for audio",
                target.index
            );
            inner.current_time = target.base_time + target.offset;
            inner.timeline.pending_seek_offset = Some(target.offset);
            inner.state = if was_active {
                PlayerState::BufferingFirstAudio
            } else {
                PlayerState::Paused
            };
            return;
        };

        inner.timeline.pending_seek_offset = None;
        let clamped = target.offset.min(audio.duration());
        let _ = self.sink.play(&audio, Duration::from_secs_f64(clamped));
        inner.current_time = target.base_time + clamped;
        log::debug!(
            "Seek {seconds:.1}s → segment {} at {clamped:.1}s ({})",
            target.index,
            if was_active { "playing" } else { "holding" }
        );
        if was_active {
            inner.state = PlayerState::Playing;
        } else {
            // The sink has no "load without playing", so hold it right back.
            self.sink.pause();
            inner.state = PlayerState::Paused;
        }
    }

    /// Advance the published playhead and pick up finished segments. Called by
    /// the driver ~10x/second; called directly by tests.
    pub fn tick(self: &Arc<Self>) {
        let finished = {
            let mut inner = self.inner.lock().unwrap();
            if inner.state != PlayerState::Playing {
                return;
            }
            let i = inner.timeline.current_index;
            if inner.decoded.contains_key(&i) {
                inner.current_time = inner.timeline.base_time + self.sink.position().as_secs_f64();
            }
            self.sink.is_finished()
        };
        if finished {
            self.advance();
        }
    }

    // MARK: - Playback helpers

    /// Decode a segment's bytes into PCM, recording its real duration (or
    /// marking it failed if the bytes don't decode). The counterpart of the
    /// Swift `makePlayer(for:)`.
    fn ensure_decoded(inner: &mut Inner, i: usize) {
        if inner.decoded.contains_key(&i) {
            return;
        }
        let Some(data) = inner.timeline.segments.get(i).and_then(|s| s.data.clone()) else {
            return;
        };
        match decode(&data) {
            Ok(audio) => {
                inner.timeline.segments[i].duration = Some(audio.duration());
                inner.decoded.insert(i, audio);
            }
            Err(e) => {
                log::error!("Segment {i} failed to decode: {e}");
                inner.timeline.segments[i].failed = true;
            }
        }
    }

    fn play_current(self: &Arc<Self>) {
        loop {
            let mut inner = self.inner.lock().unwrap();
            let i = inner.timeline.current_index;
            if i >= inner.timeline.segments.len() {
                drop(inner);
                self.finish_all();
                return;
            }
            // Skip segments that will never produce audio.
            if inner.timeline.segments[i].failed {
                inner.timeline.current_index += 1;
                continue;
            }
            Self::ensure_decoded(&mut inner, i);
            let Some(audio) = inner.decoded.get(&i).cloned() else {
                // Data not ready yet — stay buffering; the pipeline calls back.
                if inner.state != PlayerState::Paused {
                    inner.state = PlayerState::BufferingFirstAudio;
                }
                return;
            };
            // Normally enter a segment from its top. The one exception is a
            // forward scrub that parked here before the audio existed: enter at
            // that pending intra-segment offset instead of restarting from 0.
            let start_at = inner
                .timeline
                .pending_seek_offset
                .take()
                .unwrap_or(0.0)
                .clamp(0.0, audio.duration());
            match self.sink.play(&audio, Duration::from_secs_f64(start_at)) {
                Ok(()) => {
                    inner.current_time = inner.timeline.base_time + start_at;
                    inner.state = PlayerState::Playing;
                }
                Err(e) => inner.state = PlayerState::Failed(e.to_string()),
            }
            return;
        }
    }

    fn advance(self: &Arc<Self>) {
        {
            let mut inner = self.inner.lock().unwrap();
            let i = inner.timeline.current_index;
            inner.timeline.base_time += inner
                .timeline
                .segments
                .get(i)
                .and_then(|s| s.duration)
                .unwrap_or(0.0);
            inner.timeline.current_index += 1;
            if inner.timeline.current_index >= inner.timeline.segments.len() {
                drop(inner);
                self.finish_all();
                return;
            }
        }
        self.play_current();
    }

    fn finish_all(&self) {
        {
            let mut inner = self.inner.lock().unwrap();
            inner.current_time = inner.timeline.total_duration();
            inner.state = PlayerState::Finished;
        }
        if let Some(cb) = self.on_finish.lock().unwrap().as_ref() {
            cb();
        }
        // Cache publishing happens when the PIPELINE drains, not here — after a
        // forward scrub, playback can finish while skipped segments backfill.
    }

    // MARK: - Synthesis pipeline

    fn launch_synth_pipeline(self: &Arc<Self>) {
        let me = Arc::clone(self);
        tokio::spawn(async move {
            let Some(synth) = me.synthesizer.clone() else {
                return;
            };
            loop {
                if me.cancelled.load(Ordering::SeqCst) {
                    return;
                }
                let job = {
                    let inner = me.inner.lock().unwrap();
                    let Some(i) = inner.timeline.next_synth_index() else {
                        break;
                    };
                    let segs = &inner.timeline.segments;
                    Job {
                        index: i,
                        text: segs[i].text.clone(),
                        // Text conditioning: `next_text` always (that audio
                        // doesn't exist yet); `previous_text` is the fallback
                        // used when no request ids are sent. Only `text` is
                        // voiced.
                        previous_text: i.checked_sub(1).map(|p| segs[p].text.clone()),
                        next_text: segs.get(i + 1).map(|s| s.text.clone()),
                        stitch_ids: inner.timeline.stitch_ids(i),
                    }
                };

                let result = synth
                    .synthesize(SynthesisRequest {
                        text: &job.text,
                        previous_text: job.previous_text.as_deref(),
                        next_text: job.next_text.as_deref(),
                        previous_request_ids: job.stitch_ids,
                    })
                    .await;
                if me.cancelled.load(Ordering::SeqCst) {
                    return;
                }

                match result {
                    Ok(segment) => {
                        let waiting = {
                            let mut inner = me.inner.lock().unwrap();
                            inner.timeline.segments[job.index].request_id = segment.request_id;
                            inner.timeline.segments[job.index].data = Some(segment.data);
                            StreamPlayer::ensure_decoded(&mut inner, job.index);
                            // Playback is waiting on this segment (first audio,
                            // or a parked scrub) — kick it off.
                            job.index == inner.timeline.current_index
                                && inner.state == PlayerState::BufferingFirstAudio
                        };
                        if waiting {
                            me.play_current();
                        }
                    }
                    Err(e) => {
                        log::error!("Segment {} synth failed: {e}", job.index);
                        let outcome = {
                            let mut inner = me.inner.lock().unwrap();
                            inner.timeline.segments[job.index].failed = true;
                            if job.index == inner.timeline.current_index {
                                if inner.decoded.is_empty() {
                                    // Nothing has played and the segment we're
                                    // waiting on failed → give up to native.
                                    inner.state = PlayerState::Failed(e.to_string());
                                    Outcome::GiveUp
                                } else {
                                    Outcome::Advance
                                }
                            } else {
                                Outcome::Continue
                            }
                        };
                        match outcome {
                            Outcome::GiveUp => {
                                me.discard_part_file();
                                if let Some(cb) = me.on_failure.lock().unwrap().as_ref() {
                                    cb();
                                }
                                return;
                            }
                            Outcome::Advance => me.advance(),
                            Outcome::Continue => {}
                        }
                    }
                }
            }
            me.publish_cache_if_complete();
        });
    }

    // MARK: - Cache file

    fn part_path(&self) -> PathBuf {
        let mut p = self.cache_path.clone().into_os_string();
        p.push(".part");
        PathBuf::from(p)
    }

    /// Runs when the synth pipeline drains. Publishes the cache only if every
    /// segment's audio made it in — a clip with silent holes (a mid-stream synth
    /// failure) is worse than re-synthesizing on replay. Written in segment
    /// order, so the file is correct even when scrub jumps made synthesis run
    /// out of order.
    fn publish_cache_if_complete(&self) {
        if self.is_replay {
            return;
        }
        let whole = {
            let inner = self.inner.lock().unwrap();
            if !inner.timeline.is_complete() {
                None
            } else {
                Some(inner.timeline.assembled_audio())
            }
        };
        let Some(whole) = whole else {
            self.discard_part_file();
            return;
        };
        if let Some(dir) = self.cache_path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let part = self.part_path();
        // .part → rename, so History can never resolve a half-written clip.
        if let Err(e) =
            std::fs::write(&part, &whole).and_then(|_| std::fs::rename(&part, &self.cache_path))
        {
            log::error!("Cache publish failed: {e}");
            self.discard_part_file();
        }
    }

    fn discard_part_file(&self) {
        let _ = std::fs::remove_file(self.part_path());
    }
}

struct Job {
    index: usize,
    text: String,
    previous_text: Option<String>,
    next_text: Option<String>,
    stitch_ids: Vec<String>,
}

enum Outcome {
    GiveUp,
    Advance,
    Continue,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::null_sink::NullSink;
    use crate::pipeline::synthesizer::{SpeechSegment, SynthError, SynthFuture};
    use std::collections::HashSet;

    // The Swift player has no unit tests: it is @MainActor, welded to
    // AVAudioPlayer, and its seams only happen in real time. Splitting the
    // transport from the arithmetic (see timeline.rs) and putting a hand-driven
    // sink underneath makes the whole thing steppable, so these pin the transport
    // behavior the Swift original only documents in comments. They are the
    // contract to hold that side to, not a mirror of existing Swift tests.

    /// A silent mono WAV of exactly `seconds` — decodes through the same path as
    /// real MP3 segments, but with a duration the test picked.
    fn wav(seconds: f64) -> Vec<u8> {
        let rate = 8000u32;
        let frames = (seconds * rate as f64) as u32;
        let data_len = frames * 2;
        let mut b = Vec::new();
        b.extend(b"RIFF");
        b.extend((36 + data_len).to_le_bytes());
        b.extend(b"WAVE");
        b.extend(b"fmt ");
        b.extend(16u32.to_le_bytes());
        b.extend(1u16.to_le_bytes()); // PCM
        b.extend(1u16.to_le_bytes()); // mono
        b.extend(rate.to_le_bytes());
        b.extend((rate * 2).to_le_bytes());
        b.extend(2u16.to_le_bytes());
        b.extend(16u16.to_le_bytes());
        b.extend(b"data");
        b.extend(data_len.to_le_bytes());
        b.extend(std::iter::repeat_n(0u8, data_len as usize));
        b
    }

    struct FakeSynth {
        seconds: f64,
        delay: Duration,
        fail: HashSet<String>,
        calls: Mutex<Vec<String>>,
    }

    impl FakeSynth {
        fn new(seconds: f64) -> Self {
            Self {
                seconds,
                delay: Duration::from_millis(5),
                fail: HashSet::new(),
                calls: Mutex::new(Vec::new()),
            }
        }
        fn failing(mut self, texts: &[&str]) -> Self {
            self.fail = texts.iter().map(|s| s.to_string()).collect();
            self
        }
        fn slow(mut self, ms: u64) -> Self {
            self.delay = Duration::from_millis(ms);
            self
        }
    }

    impl SpeechSynthesizing for FakeSynth {
        fn synthesize<'a>(&'a self, req: SynthesisRequest<'a>) -> SynthFuture<'a> {
            let text = req.text.to_string();
            Box::pin(async move {
                self.calls.lock().unwrap().push(text.clone());
                tokio::time::sleep(self.delay).await;
                if self.fail.contains(&text) {
                    return Err(Box::<dyn std::error::Error + Send + Sync>::from(format!(
                        "synth refused {text}"
                    )) as SynthError);
                }
                Ok(SpeechSegment {
                    data: wav(self.seconds),
                    request_id: Some(format!("id-{text}")),
                })
            })
        }
    }

    struct Rig {
        player: Arc<StreamPlayer>,
        sink: Arc<NullSink>,
        synth: Arc<FakeSynth>,
        cache: PathBuf,
        _dir: tempfile::TempDir,
    }

    fn rig(sentences: &[&str], synth: FakeSynth) -> Rig {
        let dir = tempfile::tempdir().unwrap();
        let cache = dir.path().join("read.mp3");
        let sink = Arc::new(NullSink::new());
        let synth = Arc::new(synth);
        let player = StreamPlayer::new(
            sentences.iter().map(|s| s.to_string()).collect(),
            synth.clone(),
            sink.clone(),
            cache.clone(),
        );
        Rig {
            player,
            sink,
            synth,
            cache,
            _dir: dir,
        }
    }

    async fn wait_until(mut pred: impl FnMut() -> bool) -> bool {
        for _ in 0..400 {
            if pred() {
                return true;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        false
    }

    #[tokio::test]
    async fn playback_starts_as_soon_as_the_first_segment_lands() {
        let r = rig(&["Zero.", "One.", "Two."], FakeSynth::new(1.0));
        r.player.start();
        assert_eq!(r.player.state(), PlayerState::BufferingFirstAudio);

        assert!(
            wait_until(|| r.player.state() == PlayerState::Playing).await,
            "never started playing"
        );
        let plays = r.sink.plays.lock().unwrap();
        assert_eq!(plays.len(), 1, "only the first segment should have started");
        assert_eq!(
            plays[0].1,
            Duration::ZERO,
            "segments are entered from the top"
        );
    }

    #[tokio::test]
    async fn a_finished_segment_rolls_into_the_next_one() {
        let r = rig(&["Zero.", "One."], FakeSynth::new(1.0));
        r.player.start();
        assert!(wait_until(|| r.player.state() == PlayerState::Playing).await);
        assert!(wait_until(|| r.synth.calls.lock().unwrap().len() == 2).await);

        r.sink.finish_segment();
        r.player.tick();

        assert!(
            wait_until(|| r.sink.plays.lock().unwrap().len() == 2).await,
            "seam never crossed"
        );
        // The playhead now sits past the first segment's real (decoded) duration.
        let snap = r.player.snapshot();
        assert!(
            (snap.current_time - 1.0).abs() < 1e-6,
            "got {}",
            snap.current_time
        );
    }

    #[tokio::test]
    async fn finishing_the_last_segment_ends_the_read() {
        let r = rig(&["Only one."], FakeSynth::new(1.0));
        let finished = Arc::new(AtomicBool::new(false));
        let flag = finished.clone();
        r.player
            .set_on_finish(Box::new(move || flag.store(true, Ordering::SeqCst)));

        r.player.start();
        assert!(wait_until(|| r.player.state() == PlayerState::Playing).await);
        r.sink.finish_segment();
        r.player.tick();

        assert_eq!(r.player.state(), PlayerState::Finished);
        assert!(finished.load(Ordering::SeqCst), "on_finish never fired");
    }

    /// Nothing has played and the segment we're waiting on failed → give up so
    /// the coordinator can fall back to the native voice.
    #[tokio::test]
    async fn a_dead_first_segment_hands_off_instead_of_hanging() {
        let r = rig(&["Zero.", "One."], FakeSynth::new(1.0).failing(&["Zero."]));
        let failed = Arc::new(AtomicBool::new(false));
        let flag = failed.clone();
        r.player
            .set_on_failure(Box::new(move || flag.store(true, Ordering::SeqCst)));

        r.player.start();
        assert!(
            wait_until(|| failed.load(Ordering::SeqCst)).await,
            "on_failure never fired"
        );
        assert!(matches!(r.player.state(), PlayerState::Failed(_)));
    }

    /// A later segment dying is not a reason to abandon a read that is already
    /// playing — it is skipped and the read continues.
    #[tokio::test]
    async fn a_mid_stream_failure_does_not_kill_the_read() {
        let r = rig(
            &["Zero.", "One.", "Two."],
            FakeSynth::new(1.0).failing(&["One."]),
        );
        let failed = Arc::new(AtomicBool::new(false));
        let flag = failed.clone();
        r.player
            .set_on_failure(Box::new(move || flag.store(true, Ordering::SeqCst)));

        r.player.start();
        assert!(wait_until(|| r.player.state() == PlayerState::Playing).await);
        assert!(wait_until(|| r.synth.calls.lock().unwrap().len() == 3).await);

        assert!(
            !failed.load(Ordering::SeqCst),
            "a mid-stream failure must not hand off"
        );
        // Crossing the seam skips the dead segment and plays the one after it.
        r.sink.finish_segment();
        r.player.tick();
        assert!(wait_until(|| r.sink.plays.lock().unwrap().len() == 2).await);
        assert_eq!(r.player.state(), PlayerState::Playing);
    }

    #[tokio::test]
    async fn a_complete_read_publishes_one_continuous_clip() {
        let r = rig(&["Zero.", "One."], FakeSynth::new(0.5));
        r.player.start();

        assert!(
            wait_until(|| r.cache.exists()).await,
            "cache was never published"
        );
        let written = std::fs::read(&r.cache).unwrap();
        assert_eq!(
            written.len(),
            wav(0.5).len() * 2,
            "clip should be both segments, in order"
        );
        assert!(
            !r.cache.with_extension("mp3.part").exists(),
            "temp file left behind"
        );
    }

    /// A clip with silent holes is worse than re-synthesizing on replay.
    #[tokio::test]
    async fn a_read_with_a_hole_publishes_nothing() {
        let r = rig(
            &["Zero.", "One.", "Two."],
            FakeSynth::new(0.5).failing(&["One."]),
        );
        r.player.start();
        assert!(wait_until(|| r.synth.calls.lock().unwrap().len() == 3).await);
        // Let the pipeline drain past its last request.
        tokio::time::sleep(Duration::from_millis(50)).await;

        assert!(
            !r.cache.exists(),
            "an incomplete read must not publish a cache clip"
        );
        assert!(!r.cache.with_extension("mp3.part").exists());
    }

    #[tokio::test]
    async fn pause_holds_the_transport_and_resume_picks_it_back_up() {
        let r = rig(&["Zero.", "One."], FakeSynth::new(1.0));
        r.player.start();
        assert!(wait_until(|| r.player.state() == PlayerState::Playing).await);

        r.player.pause();
        assert_eq!(r.player.state(), PlayerState::Paused);
        assert!(r.sink.is_paused());

        r.player.resume();
        assert_eq!(r.player.state(), PlayerState::Playing);
        assert!(!r.sink.is_paused());
        // Resuming must not restart the segment.
        assert_eq!(r.sink.plays.lock().unwrap().len(), 1);
    }

    /// A scrub past the synthesized buffer parks the needle where the user
    /// dropped it, redirects the pipeline to that segment, and starts there —
    /// mid-segment — when the audio lands.
    #[tokio::test]
    async fn a_scrub_past_the_buffer_parks_and_resumes_at_the_drop_point() {
        let r = rig(&["Zero.", "One.", "Two."], FakeSynth::new(2.0).slow(60));
        r.player.start();
        assert!(wait_until(|| r.player.state() == PlayerState::Playing).await);

        // Aim at the middle of the last transcript line, which has no audio yet.
        let snap = r.player.snapshot();
        let last = snap.transcript.last().cloned().expect("transcript");
        let target = (last.start + last.end) / 2.0;
        assert!(!last.is_loaded, "test needs an unsynthesized tail");

        r.player.seek(target);
        assert_eq!(
            r.player.state(),
            PlayerState::BufferingFirstAudio,
            "a scrub past the buffer should park, not fail"
        );
        assert!((r.player.snapshot().current_time - target).abs() < 1e-6);

        assert!(
            wait_until(|| r.sink.plays.lock().unwrap().len() >= 2).await,
            "parked scrub never resumed"
        );
        let entered_at = r.sink.plays.lock().unwrap().last().unwrap().1;
        assert!(
            entered_at > Duration::ZERO,
            "should have entered the segment mid-way, not from the top"
        );
        assert_eq!(r.player.state(), PlayerState::Playing);
    }

    #[tokio::test]
    async fn a_scrub_while_paused_stays_paused() {
        let r = rig(&["Zero.", "One."], FakeSynth::new(1.0));
        r.player.start();
        assert!(wait_until(|| r.player.state() == PlayerState::Playing).await);
        r.player.pause();

        r.player.seek(0.25);
        assert_eq!(r.player.state(), PlayerState::Paused);
        assert!(
            r.sink.is_paused(),
            "a scrub must not start playback that was held"
        );
    }

    #[tokio::test]
    async fn rates_step_and_cycle_within_the_allowed_set() {
        let r = rig(&["Zero."], FakeSynth::new(1.0));
        r.player.set_rate(1.5);
        assert_eq!(r.sink.rate(), 1.5);

        r.player.step_rate(true);
        assert_eq!(r.player.snapshot().rate, 1.75);
        r.player.step_rate(false);
        assert_eq!(r.player.snapshot().rate, 1.5);

        // Clamped at the ends rather than wrapping.
        r.player.set_rate(99.0);
        assert_eq!(r.player.snapshot().rate, 2.0);
        r.player.step_rate(true);
        assert_eq!(r.player.snapshot().rate, 2.0);

        // Cycling wraps.
        r.player.cycle_rate();
        assert_eq!(r.player.snapshot().rate, 1.0);
    }

    #[tokio::test]
    async fn stopping_mid_read_leaves_no_cache_and_no_temp_file() {
        let r = rig(&["Zero.", "One.", "Two."], FakeSynth::new(1.0).slow(40));
        r.player.start();
        assert!(wait_until(|| r.player.state() == PlayerState::Playing).await);

        r.player.stop();
        assert_eq!(r.player.state(), PlayerState::Idle);
        tokio::time::sleep(Duration::from_millis(120)).await;
        assert!(!r.cache.exists());
        assert!(!r.cache.with_extension("mp3.part").exists());
    }
}
