//! Thin client for ElevenLabs' TTS endpoint — port of
//! `Yapper/Services/ElevenLabsClient.swift`.
//!
//!   POST /v1/text-to-speech/{voice_id}/stream
//!
//! Request/response shapes, defaults, and header handling mirror the Swift
//! client exactly so both apps talk to the API identically.

use serde::Serialize;

pub const DEFAULT_MODEL_ID: &str = "eleven_flash_v2_5";
pub const DEFAULT_OUTPUT_FORMAT: &str = "mp3_44100_128";

#[derive(Debug, thiserror::Error)]
pub enum ClientError {
    #[error("No ElevenLabs API key configured.")]
    MissingApiKey,
    #[error("ElevenLabs HTTP {status}{}", body.as_deref().map(|b| format!(": {b}")).unwrap_or_default())]
    Http { status: u16, body: Option<String> },
    #[error(transparent)]
    Transport(#[from] reqwest::Error),
}

/// Prosody controls sent with every request. If omitted, ElevenLabs uses the
/// voice's stored defaults — typically stability ~0.5, which reads flat.
/// These are the dials that stop the read from sounding robotic.
#[derive(Clone, Debug, Serialize)]
pub struct VoiceSettings {
    pub stability: f64,
    pub similarity_boost: f64,
    pub style: f64,
    pub use_speaker_boost: bool,
}

impl VoiceSettings {
    /// Natural, lightly expressive reading voice — matches the tuned macOS
    /// default (`VoiceSettings.natural`): de-monotoned but composed. No
    /// model-side `speed`: sped-up variants auditioned less human.
    pub fn natural() -> Self {
        Self {
            stability: 0.40,
            similarity_boost: 0.80,
            style: 0.30,
            use_speaker_boost: true,
        }
    }
}

pub struct Request {
    pub voice_id: String,
    pub text: String,
    pub model_id: String,
    pub output_format: String,
    pub voice_settings: VoiceSettings,
    /// Prosodic conditioning: adjacent chunks' text so the model carries
    /// intonation across segment seams. Not voiced.
    pub previous_text: Option<String>,
    pub next_text: Option<String>,
    /// Request stitching: ids of segments already synthesized (oldest → newest).
    /// The API conditions on that *audio* and ignores `previous_text` when set.
    pub previous_request_ids: Vec<String>,
}

impl Request {
    pub fn new(voice_id: impl Into<String>, text: impl Into<String>) -> Self {
        Self {
            voice_id: voice_id.into(),
            text: text.into(),
            model_id: DEFAULT_MODEL_ID.to_string(),
            output_format: DEFAULT_OUTPUT_FORMAT.to_string(),
            voice_settings: VoiceSettings::natural(),
            previous_text: None,
            next_text: None,
            previous_request_ids: Vec::new(),
        }
    }
}

/// The JSON body. Optional context fields are omitted when absent (matching the
/// Swift client's `encodeIfPresent` behavior), so first/last segments simply
/// don't carry `previous_text` / `next_text`.
#[derive(Serialize)]
struct Body<'a> {
    text: &'a str,
    model_id: &'a str,
    voice_settings: &'a VoiceSettings,
    #[serde(skip_serializing_if = "Option::is_none")]
    previous_text: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    next_text: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    previous_request_ids: Option<Vec<String>>,
}

impl<'a> Body<'a> {
    fn from(req: &'a Request) -> Self {
        Self {
            text: &req.text,
            model_id: &req.model_id,
            voice_settings: &req.voice_settings,
            previous_text: req.previous_text.as_deref(),
            next_text: req.next_text.as_deref(),
            // The API accepts at most 3 ids; keep the most recent ones.
            previous_request_ids: if req.previous_request_ids.is_empty() {
                None
            } else {
                let ids = &req.previous_request_ids;
                Some(ids[ids.len().saturating_sub(3)..].to_vec())
            },
        }
    }
}

pub struct SynthesisResult {
    pub data: Vec<u8>,
    /// The `request-id` response header — pass it as `previous_request_ids` on
    /// the next segment so consecutive generations stitch into one performance.
    pub request_id: Option<String>,
}

/// Synthesize a single segment and return the complete MP3 data plus its
/// request id. Segments are small enough to fetch in one go; a streaming
/// variant can come with the player (Phase 2).
pub async fn synthesize(req: &Request, api_key: &str) -> Result<SynthesisResult, ClientError> {
    if api_key.is_empty() {
        return Err(ClientError::MissingApiKey);
    }

    let url = format!(
        "https://api.elevenlabs.io/v1/text-to-speech/{}/stream",
        req.voice_id
    );
    let resp = reqwest::Client::new()
        .post(&url)
        .query(&[("output_format", req.output_format.as_str())])
        .header("Accept", "audio/mpeg")
        .header("xi-api-key", api_key)
        .json(&Body::from(req))
        .send()
        .await?;

    let status = resp.status();
    let request_id = resp
        .headers()
        .get("request-id")
        .and_then(|v| v.to_str().ok())
        .map(String::from);

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

    let data = resp.bytes().await?.to_vec();
    Ok(SynthesisResult { data, request_id })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn body_omits_absent_context_fields() {
        let req = Request::new("21m00Tcm4TlvDq8ikWAM", "Hello.");
        let json = serde_json::to_value(Body::from(&req)).unwrap();
        assert_eq!(json["text"], "Hello.");
        assert_eq!(json["model_id"], DEFAULT_MODEL_ID);
        assert_eq!(json["voice_settings"]["stability"], 0.40);
        assert_eq!(json["voice_settings"]["use_speaker_boost"], true);
        assert!(json.get("previous_text").is_none());
        assert!(json.get("next_text").is_none());
        assert!(json.get("previous_request_ids").is_none());
    }

    #[test]
    fn body_keeps_only_last_three_request_ids() {
        let mut req = Request::new("v", "t");
        req.previous_request_ids = vec!["a", "b", "c", "d"]
            .into_iter()
            .map(String::from)
            .collect();
        let json = serde_json::to_value(Body::from(&req)).unwrap();
        assert_eq!(
            json["previous_request_ids"],
            serde_json::json!(["b", "c", "d"])
        );
    }
}
