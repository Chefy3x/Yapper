//! A sink that makes no sound and is driven by hand.
//!
//! Two jobs. In tests it stands in for a sound card so the player's transport
//! logic — seams, seeks, parked scrubs — can be stepped deterministically
//! instead of waited on in real time. At runtime it's the graceful fallback when
//! the machine has no usable output device: the pipeline still runs, History
//! still fills, nothing panics; the user just hears nothing until they fix their
//! audio.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use super::{AudioError, AudioSink, DecodedAudio};

#[derive(Default)]
#[allow(dead_code)] // hand-driving helpers are test-facing
pub struct NullSink {
    position_ms: AtomicU64,
    finished: AtomicBool,
    paused: AtomicBool,
    rate: Mutex<f32>,
    /// Every (segment duration, start offset) this sink was asked to play, in
    /// order — lets a test assert *where* playback entered each segment.
    pub plays: Mutex<Vec<(f64, Duration)>>,
}

#[allow(dead_code)]
impl NullSink {
    pub fn new() -> Self {
        Self::default()
    }

    // The methods below drive the sink by hand from tests; the runtime
    // fallback path only ever uses the `AudioSink` impl.
    /// Move the playhead within the current segment.
    pub fn advance_to(&self, pos: Duration) {
        self.position_ms
            .store(pos.as_millis() as u64, Ordering::SeqCst);
    }

    /// The current segment reached its end — what a real device reports by
    /// draining its queue.
    pub fn finish_segment(&self) {
        self.finished.store(true, Ordering::SeqCst);
    }

    pub fn is_paused(&self) -> bool {
        self.paused.load(Ordering::SeqCst)
    }

    pub fn rate(&self) -> f32 {
        *self.rate.lock().unwrap()
    }
}

impl AudioSink for NullSink {
    fn play(&self, audio: &DecodedAudio, from: Duration) -> Result<(), AudioError> {
        self.plays.lock().unwrap().push((audio.duration(), from));
        self.position_ms
            .store(from.as_millis() as u64, Ordering::SeqCst);
        self.finished.store(false, Ordering::SeqCst);
        self.paused.store(false, Ordering::SeqCst);
        Ok(())
    }

    fn pause(&self) {
        self.paused.store(true, Ordering::SeqCst);
    }

    fn resume(&self) {
        self.paused.store(false, Ordering::SeqCst);
    }

    fn stop(&self) {
        self.position_ms.store(0, Ordering::SeqCst);
        self.finished.store(false, Ordering::SeqCst);
    }

    fn set_rate(&self, rate: f32) {
        *self.rate.lock().unwrap() = rate;
    }

    fn position(&self) -> Duration {
        Duration::from_millis(self.position_ms.load(Ordering::SeqCst))
    }

    fn is_finished(&self) -> bool {
        self.finished.load(Ordering::SeqCst)
    }
}
