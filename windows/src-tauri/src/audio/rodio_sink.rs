//! Real output: rodio over CoreAudio (macOS) / WASAPI (Windows).
//!
//! rodio 0.22 names the device stream `MixerDeviceSink` and the per-source
//! transport `Player` (the old `OutputStream` / `Sink`). One `Player` holds one
//! segment; starting the next segment replaces it, which is what makes seams
//! land cleanly.

use std::num::NonZero;
use std::sync::Mutex;
use std::time::Duration;

use super::{AudioError, AudioSink, DecodedAudio};

pub struct RodioSink {
    // The device sink must outlive every Player connected to its mixer.
    stream: rodio::MixerDeviceSink,
    inner: Mutex<Option<rodio::Player>>,
    /// Where in the segment the current source was told to begin, so
    /// `position()` reports segment-relative time rather than source-relative.
    start_offset: Mutex<Duration>,
    rate: Mutex<f32>,
}

impl RodioSink {
    pub fn new() -> Result<Self, AudioError> {
        let stream = rodio::DeviceSinkBuilder::open_default_sink()
            .map_err(|e| AudioError::Output(e.to_string()))?;
        Ok(Self {
            stream,
            inner: Mutex::new(None),
            start_offset: Mutex::new(Duration::ZERO),
            rate: Mutex::new(1.0),
        })
    }
}

impl AudioSink for RodioSink {
    fn play(&self, audio: &DecodedAudio, from: Duration) -> Result<(), AudioError> {
        let channels = NonZero::new(audio.channels)
            .ok_or_else(|| AudioError::Decode("zero channels".into()))?;
        let sample_rate = NonZero::new(audio.sample_rate)
            .ok_or_else(|| AudioError::Decode("zero sample rate".into()))?;
        let source =
            rodio::buffer::SamplesBuffer::new(channels, sample_rate, audio.slice_from(from));

        let player = rodio::Player::connect_new(self.stream.mixer());
        player.set_speed(*self.rate.lock().unwrap());
        player.append(source);
        player.play();

        *self.start_offset.lock().unwrap() = from;
        // Replacing the previous player drops it, stopping whatever it held.
        *self.inner.lock().unwrap() = Some(player);
        Ok(())
    }

    fn pause(&self) {
        if let Some(p) = self.inner.lock().unwrap().as_ref() {
            p.pause();
        }
    }

    fn resume(&self) {
        if let Some(p) = self.inner.lock().unwrap().as_ref() {
            p.play();
        }
    }

    fn stop(&self) {
        if let Some(p) = self.inner.lock().unwrap().take() {
            p.stop();
        }
        *self.start_offset.lock().unwrap() = Duration::ZERO;
    }

    fn set_rate(&self, rate: f32) {
        *self.rate.lock().unwrap() = rate;
        if let Some(p) = self.inner.lock().unwrap().as_ref() {
            p.set_speed(rate);
        }
    }

    fn position(&self) -> Duration {
        let offset = *self.start_offset.lock().unwrap();
        match self.inner.lock().unwrap().as_ref() {
            Some(p) => offset + p.get_pos(),
            None => offset,
        }
    }

    fn is_finished(&self) -> bool {
        match self.inner.lock().unwrap().as_ref() {
            Some(p) => p.empty(),
            None => false,
        }
    }
}
