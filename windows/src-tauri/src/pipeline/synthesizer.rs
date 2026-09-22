//! One provider's segment synthesis, seen from the streaming player — port of
//! the `SpeechSynthesizing` protocol in `Yapper/Services/SpeechSynthesizing.swift`.
//!
//! The player stays deliberately ignorant of who is speaking: it schedules
//! segments, tracks the playhead and assembles the cache. Everything
//! provider-shaped — auth, model ids, prosodic conditioning, stitching — lives
//! behind this single call.

use std::future::Future;
use std::pin::Pin;

use super::{elevenlabs, openai};

/// One segment of synthesized speech.
pub struct SpeechSegment {
    pub data: Vec<u8>,
    /// Provider-side handle for stitching the next generation onto this one.
    /// Providers without that concept return `None` and lose nothing but a
    /// little continuity across sentence seams.
    pub request_id: Option<String>,
}

/// Conditioning context for one segment. Only `text` is voiced.
pub struct SynthesisRequest<'a> {
    pub text: &'a str,
    pub previous_text: Option<&'a str>,
    pub next_text: Option<&'a str>,
    pub previous_request_ids: Vec<String>,
}

pub type SynthError = Box<dyn std::error::Error + Send + Sync>;
pub type SynthFuture<'a> =
    Pin<Box<dyn Future<Output = Result<SpeechSegment, SynthError>> + Send + 'a>>;

pub trait SpeechSynthesizing: Send + Sync {
    fn synthesize<'a>(&'a self, req: SynthesisRequest<'a>) -> SynthFuture<'a>;
}

/// ElevenLabs, with the full conditioning contract: neighbouring text for
/// prosody, and request stitching so consecutive segments sound like one
/// continuous performance rather than a series of separately-recorded lines.
pub struct ElevenLabsSynthesizer {
    pub voice_id: String,
    pub model_id: String,
    pub output_format: String,
    pub voice_settings: elevenlabs::VoiceSettings,
    pub api_key: String,
}

impl SpeechSynthesizing for ElevenLabsSynthesizer {
    fn synthesize<'a>(&'a self, req: SynthesisRequest<'a>) -> SynthFuture<'a> {
        Box::pin(async move {
            let mut r = elevenlabs::Request::new(self.voice_id.clone(), req.text);
            r.model_id = self.model_id.clone();
            r.output_format = self.output_format.clone();
            r.voice_settings = self.voice_settings.clone();
            r.previous_text = req.previous_text.map(String::from);
            r.next_text = req.next_text.map(String::from);
            r.previous_request_ids = req.previous_request_ids;
            let result = elevenlabs::synthesize(&r, &self.api_key).await?;
            Ok(SpeechSegment {
                data: result.data,
                request_id: result.request_id,
            })
        })
    }
}

/// OpenAI. The API offers neither stitching nor neighbour conditioning, so
/// those arguments are accepted and dropped rather than faked into something
/// that reads like continuity.
pub struct OpenAISynthesizer {
    pub voice: String,
    pub model_id: String,
    pub api_key: String,
}

impl SpeechSynthesizing for OpenAISynthesizer {
    fn synthesize<'a>(&'a self, req: SynthesisRequest<'a>) -> SynthFuture<'a> {
        Box::pin(async move {
            let mut r = openai::Request::new(self.voice.clone(), req.text);
            r.model_id = self.model_id.clone();
            let data = openai::synthesize(&r, &self.api_key).await?;
            Ok(SpeechSegment {
                data,
                request_id: None,
            })
        })
    }
}
