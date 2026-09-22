//! Thin client for OpenAI's speech endpoint — port of
//! `Yapper/Services/OpenAIClient.swift`.
//!
//!   POST /v1/audio/speech
//!
//! Deliberately narrower than `elevenlabs`: OpenAI has no request-stitching or
//! previous/next-text conditioning, so each segment is synthesized in isolation.
//! In practice that costs a little prosodic continuity across sentence seams and
//! buys a much simpler client.

use serde::Serialize;

#[derive(Debug, thiserror::Error)]
pub enum ClientError {
    #[error("No OpenAI API key configured.")]
    MissingApiKey,
    #[error("OpenAI HTTP {status}{}", body.as_deref().map(|b| format!(": {b}")).unwrap_or_default())]
    Http { status: u16, body: Option<String> },
    #[error(transparent)]
    Transport(#[from] reqwest::Error),
}

/// Matches the tuning ElevenLabs gets through `VoiceSettings::natural` —
/// composed and lightly expressive rather than the flat default read.
pub const DEFAULT_INSTRUCTIONS: &str =
    "Read this aloud naturally and unhurried, like a person reading something they find worth reading.";

pub struct Request {
    pub voice: String,
    pub text: String,
    pub model_id: String,
    pub response_format: String,
    /// Free-text delivery direction. Honoured by `gpt-4o-mini-tts` and ignored
    /// by the older `tts-1` models, which is why it's never required.
    pub instructions: Option<String>,
}

impl Request {
    pub fn new(voice: impl Into<String>, text: impl Into<String>) -> Self {
        Self {
            voice: voice.into(),
            text: text.into(),
            model_id: Model::DEFAULT.as_str().to_string(),
            response_format: "mp3".to_string(),
            instructions: Some(DEFAULT_INSTRUCTIONS.to_string()),
        }
    }
}

#[derive(Serialize)]
struct Body<'a> {
    model: &'a str,
    input: &'a str,
    voice: &'a str,
    response_format: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    instructions: Option<&'a str>,
}

impl<'a> Body<'a> {
    fn from(req: &'a Request) -> Self {
        Self {
            model: &req.model_id,
            input: &req.text,
            voice: &req.voice,
            response_format: &req.response_format,
            // Sent only where it means something; tts-1 rejects unknown fields
            // less gracefully than it ignores them.
            instructions: if req.model_id.starts_with("gpt-4o") {
                req.instructions.as_deref()
            } else {
                None
            },
        }
    }
}

/// Synthesize one segment. Returns the complete audio data.
pub async fn synthesize(req: &Request, api_key: &str) -> Result<Vec<u8>, ClientError> {
    if api_key.is_empty() {
        return Err(ClientError::MissingApiKey);
    }

    let resp = reqwest::Client::new()
        .post("https://api.openai.com/v1/audio/speech")
        .header("Authorization", format!("Bearer {api_key}"))
        .json(&Body::from(req))
        .send()
        .await?;

    let status = resp.status();
    if !status.is_success() {
        let body = resp
            .text()
            .await
            .ok()
            .map(|b| b.chars().take(2048).collect());
        return Err(ClientError::Http {
            status: status.as_u16(),
            body,
        });
    }
    Ok(resp.bytes().await?.to_vec())
}

/// The speech models OpenAI currently offers, cheapest-and-fastest first.
/// Mirrors the Swift `OpenAIModel` enum, including the copy the settings pane
/// shows, so both apps describe the same choice in the same words.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Model {
    Gpt4oMiniTts,
    Tts1,
    Tts1Hd,
}

impl Model {
    pub const DEFAULT: Model = Model::Gpt4oMiniTts;
    pub const ALL: [Model; 3] = [Model::Gpt4oMiniTts, Model::Tts1, Model::Tts1Hd];

    pub fn as_str(self) -> &'static str {
        match self {
            Model::Gpt4oMiniTts => "gpt-4o-mini-tts",
            Model::Tts1 => "tts-1",
            Model::Tts1Hd => "tts-1-hd",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Model::Gpt4oMiniTts => "GPT-4o mini TTS",
            Model::Tts1 => "TTS-1",
            Model::Tts1Hd => "TTS-1 HD",
        }
    }

    pub fn blurb(self) -> &'static str {
        match self {
            Model::Gpt4oMiniTts => "Newest. Takes delivery direction, best quality for the price.",
            Model::Tts1 => "Older and lower latency. Flatter read.",
            Model::Tts1Hd => "Older, higher fidelity, slower and dearer.",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn instructions_ride_along_on_gpt4o_models() {
        let req = Request::new("alloy", "Hello.");
        let json = serde_json::to_value(Body::from(&req)).unwrap();
        assert_eq!(json["model"], "gpt-4o-mini-tts");
        assert_eq!(json["input"], "Hello.");
        assert_eq!(json["response_format"], "mp3");
        assert_eq!(json["instructions"], DEFAULT_INSTRUCTIONS);
    }

    /// The Swift client drops `instructions` for the tts-1 family rather than
    /// sending a field those models handle badly.
    #[test]
    fn instructions_are_dropped_for_tts1() {
        let mut req = Request::new("alloy", "Hello.");
        req.model_id = Model::Tts1.as_str().to_string();
        let json = serde_json::to_value(Body::from(&req)).unwrap();
        assert!(json.get("instructions").is_none());
    }
}
