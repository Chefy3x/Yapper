//! Decoding and output — the `AVAudioPlayer` half of the Mac player.
//!
//! Segment audio is decoded to interleaved f32 PCM up front rather than streamed
//! from the compressed bytes. That mirrors `AVAudioPlayer(data:)`: the exact
//! duration is known the moment a segment lands (the pipeline needs it to keep
//! the scrubber scale honest), and seeking inside a segment is a slice instead
//! of a decoder seek. Segments are one-to-a-few sentences, so the memory this
//! costs is trivial.

use std::io::Cursor;
use std::time::Duration;

use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::DecoderOptions;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

#[derive(Debug, thiserror::Error)]
pub enum AudioError {
    #[error("could not decode audio: {0}")]
    Decode(String),
    #[error("no audio output device: {0}")]
    Output(String),
}

#[derive(Clone, Debug)]
pub struct DecodedAudio {
    pub samples: Vec<f32>,
    pub channels: u16,
    pub sample_rate: u32,
}

impl DecodedAudio {
    pub fn duration(&self) -> f64 {
        let frames = self.samples.len() / self.channels.max(1) as usize;
        frames as f64 / self.sample_rate.max(1) as f64
    }

    /// The tail of the clip starting at `from` — how a seek inside a segment is
    /// served.
    fn slice_from(&self, from: Duration) -> Vec<f32> {
        let frame = (from.as_secs_f64() * self.sample_rate as f64) as usize;
        let idx = (frame * self.channels as usize).min(self.samples.len());
        self.samples[idx..].to_vec()
    }
}

/// Decode a complete MP3 (ElevenLabs/OpenAI) or WAV (WinRT speech) buffer.
pub fn decode(bytes: &[u8]) -> Result<DecodedAudio, AudioError> {
    let source = Box::new(Cursor::new(bytes.to_vec()));
    let mss = MediaSourceStream::new(source, Default::default());
    let probed = symphonia::default::get_probe()
        .format(
            &Hint::new(),
            mss,
            &FormatOptions::default(),
            &MetadataOptions::default(),
        )
        .map_err(|e| AudioError::Decode(e.to_string()))?;

    let mut format = probed.format;
    let track = format
        .default_track()
        .ok_or_else(|| AudioError::Decode("no default track".into()))?;
    let track_id = track.id;
    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .map_err(|e| AudioError::Decode(e.to_string()))?;

    let mut samples: Vec<f32> = Vec::new();
    let mut channels = 0u16;
    let mut sample_rate = 0u32;

    // Ends on end-of-stream, or on a truncated tail — whatever decoded before
    // the break is still worth playing.
    while let Ok(packet) = format.next_packet() {
        if packet.track_id() != track_id {
            continue;
        }
        let decoded = match decoder.decode(&packet) {
            Ok(d) => d,
            Err(symphonia::core::errors::Error::DecodeError(_)) => continue,
            Err(e) => return Err(AudioError::Decode(e.to_string())),
        };
        let spec = *decoded.spec();
        channels = spec.channels.count() as u16;
        sample_rate = spec.rate;
        let mut buf = SampleBuffer::<f32>::new(decoded.capacity() as u64, spec);
        buf.copy_interleaved_ref(decoded);
        samples.extend_from_slice(buf.samples());
    }

    if samples.is_empty() || channels == 0 || sample_rate == 0 {
        return Err(AudioError::Decode("decoded to no audio".into()));
    }
    Ok(DecodedAudio {
        samples,
        channels,
        sample_rate,
    })
}

/// What the player needs from an output device. Abstracted so the scheduling
/// logic can be exercised headlessly — CI has no sound card, and the parity
/// tests must not need one.
pub trait AudioSink: Send + Sync {
    fn play(&self, audio: &DecodedAudio, from: Duration) -> Result<(), AudioError>;
    fn pause(&self);
    fn resume(&self);
    fn stop(&self);
    fn set_rate(&self, rate: f32);
    /// Position *within the current segment*, including the offset it began at.
    fn position(&self) -> Duration;
    /// The current segment played to its end on its own. The player polls this
    /// where the Swift original gets `audioPlayerDidFinishPlaying`.
    fn is_finished(&self) -> bool;
}

pub mod null_sink;
pub mod rodio_sink;

#[cfg(test)]
mod tests {
    use super::*;

    /// Every provider hands back MP3, so this is the decode path the whole app
    /// depends on — the player's own tests use WAV because they need to pick
    /// exact durations, which would leave MP3 uncovered.
    ///
    /// The fixture is a 0.5 s 440 Hz tone; MP3 is block-based, so the decoded
    /// length lands within a frame or two of nominal rather than exactly on it.
    #[test]
    fn decodes_mp3_to_pcm_with_a_sane_duration() {
        let bytes = include_bytes!("../../tests/fixtures/tone-0.5s.mp3");
        let audio = decode(bytes).expect("fixture should decode");
        assert_eq!(audio.sample_rate, 44_100);
        assert_eq!(audio.channels, 1);
        assert!(
            (audio.duration() - 0.5).abs() < 0.08,
            "expected ~0.5s, got {}",
            audio.duration()
        );
        assert!(
            audio.samples.iter().any(|s| s.abs() > 0.01),
            "decoded to silence"
        );
    }

    /// A seek inside a segment is served by slicing the decoded buffer, so the
    /// remaining length has to match what's left of the clip.
    #[test]
    fn slicing_returns_the_tail_of_the_clip() {
        let bytes = include_bytes!("../../tests/fixtures/tone-0.5s.mp3");
        let audio = decode(bytes).unwrap();
        let half = audio.slice_from(Duration::from_secs_f64(audio.duration() / 2.0));
        let ratio = half.len() as f64 / audio.samples.len() as f64;
        assert!((ratio - 0.5).abs() < 0.02, "got {ratio}");
        assert!(
            audio.slice_from(Duration::from_secs(60)).is_empty(),
            "past the end is empty"
        );
    }

    #[test]
    fn garbage_is_rejected_rather_than_played_as_noise() {
        assert!(decode(b"not audio at all").is_err());
        assert!(decode(&[]).is_err());
    }
}
