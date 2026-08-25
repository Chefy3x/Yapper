//! Shared value types — ports of `Yapper/Models/`.

use serde::{Deserialize, Serialize};

/// One unit of "thing Yapper is reading aloud right now (or read recently)."
/// Port of `ReadingItem.swift`.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReadingItem {
    pub id: String,
    pub source_app: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub cleaned_text: String,
    pub raw_text: String,
}

impl ReadingItem {
    pub fn make(
        source_app: impl Into<String>,
        cleaned: impl Into<String>,
        raw: impl Into<String>,
    ) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            source_app: source_app.into(),
            created_at: chrono::Utc::now(),
            cleaned_text: cleaned.into(),
            raw_text: raw.into(),
        }
    }

    pub fn preview(&self) -> String {
        preview(&self.cleaned_text, 60)
    }
}

/// Flatten to one line and truncate with an ellipsis. Shared by `ReadingItem`
/// (60) and `HistoryEntry` (90), matching the Swift previews.
///
/// Divergence: counts Unicode scalars where Swift counts grapheme clusters, so
/// a preview cut mid-emoji-sequence could differ by a character.
pub(crate) fn preview(text: &str, limit: usize) -> String {
    let one_line = text.replace('\n', " ");
    let one_line = one_line.trim_matches(|c: char| c == ' ' || c == '\t');
    if one_line.chars().count() <= limit {
        return one_line.to_string();
    }
    let head: String = one_line.chars().take(limit).collect();
    format!("{head}…")
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum TtsProvider {
    #[serde(rename = "elevenLabs")]
    ElevenLabs,
    #[serde(rename = "openAI")]
    OpenAI,
    /// The OS voice. Named for its Mac counterpart in the shared settings
    /// vocabulary; on Windows this is WinRT speech (see `native_tts`).
    #[serde(rename = "macOSNative")]
    SystemNative,
}

/// Port of `VoicePreset.swift`. The catalog is kept identical to the Mac app's
/// so a voice chosen on one platform means the same thing on the other.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VoicePreset {
    pub id: String,
    pub display_name: String,
    pub provider: TtsProvider,
    pub provider_voice_id: String,
    pub language: String,
    #[serde(default)]
    pub is_custom: bool,
}

impl VoicePreset {
    fn new(id: &str, display_name: &str, provider: TtsProvider, voice_id: &str) -> Self {
        Self {
            id: id.into(),
            display_name: display_name.into(),
            provider,
            provider_voice_id: voice_id.into(),
            language: "en".into(),
            is_custom: false,
        }
    }

    pub fn default_preset() -> Self {
        Self::new(
            "rachel",
            "Rachel",
            TtsProvider::ElevenLabs,
            "21m00Tcm4TlvDq8ikWAM",
        )
    }

    pub fn presets() -> Vec<VoicePreset> {
        use TtsProvider::*;
        vec![
            Self::default_preset(),
            Self::new("chris", "Chris", ElevenLabs, "iP95p4xoKVk53GoZ742B"),
            Self::new("river", "River", ElevenLabs, "SAz9YHcvj6GT2YYXdXww"),
            Self::new("adam", "Adam", ElevenLabs, "pNInz6obpgDQGcFmaJgB"),
            Self::new("bella", "Bella", ElevenLabs, "EXAVITQu4vr4xnSDxMaL"),
            Self::new("antoni", "Antoni", ElevenLabs, "ErXwobaYiN019PkySvjV"),
            // The Mac preset is a macOS voice identifier; on Windows the system
            // voice is whatever WinRT reports as the default, so the id is empty.
            Self::new("system", "Windows System", SystemNative, ""),
            // OpenAI. `marin` and `cedar` are the current best-quality pair and
            // are listed first; the rest are the long-standing set that the
            // older tts-1 models also accept.
            Self::new("openai-marin", "Marin", OpenAI, "marin"),
            Self::new("openai-cedar", "Cedar", OpenAI, "cedar"),
            Self::new("openai-alloy", "Alloy", OpenAI, "alloy"),
            Self::new("openai-echo", "Echo", OpenAI, "echo"),
            Self::new("openai-fable", "Fable", OpenAI, "fable"),
            Self::new("openai-onyx", "Onyx", OpenAI, "onyx"),
            Self::new("openai-nova", "Nova", OpenAI, "nova"),
            Self::new("openai-shimmer", "Shimmer", OpenAI, "shimmer"),
        ]
    }
}

/// Port of the Swift `ElevenLabsModel` enum, including the per-request
/// character ceilings the coordinator warns against.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ElevenLabsModel {
    FlashV25,
    MultilingualV2,
}

impl ElevenLabsModel {
    pub const DEFAULT: ElevenLabsModel = ElevenLabsModel::FlashV25;
    pub const ALL: [ElevenLabsModel; 2] =
        [ElevenLabsModel::FlashV25, ElevenLabsModel::MultilingualV2];

    pub fn as_str(self) -> &'static str {
        match self {
            ElevenLabsModel::FlashV25 => "eleven_flash_v2_5",
            ElevenLabsModel::MultilingualV2 => "eleven_multilingual_v2",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|m| m.as_str() == s)
    }

    pub fn display_name(self) -> &'static str {
        match self {
            ElevenLabsModel::FlashV25 => "Flash v2.5 (faster, ~75ms)",
            ElevenLabsModel::MultilingualV2 => "Multilingual v2 (higher fidelity)",
        }
    }

    /// Max input character count per request, per ElevenLabs.
    pub fn character_limit(self) -> usize {
        match self {
            ElevenLabsModel::FlashV25 => 40_000,
            ElevenLabsModel::MultilingualV2 => 10_000,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Mirrors `previewFlattensNewlinesAndTruncates` in
    /// `YapperTests/HistoryStoreTests.swift`.
    #[test]
    fn preview_flattens_newlines_and_truncates() {
        let long = vec!["word"; 40].join("\n"); // 199 chars
        let p = preview(&long, 60);
        assert!(!p.contains('\n'));
        assert!(p.ends_with('…'));
        assert_eq!(p.chars().count(), 61);
        assert_eq!(preview(&long, 90).chars().count(), 91);
    }

    #[test]
    fn short_text_is_not_truncated() {
        assert_eq!(preview("one\ntwo", 60), "one two");
    }

    /// The voice catalog is a cross-platform contract: an id chosen in the Mac
    /// app has to resolve to the same provider voice here.
    #[test]
    fn the_voice_catalog_matches_the_mac_app() {
        let presets = VoicePreset::presets();
        assert_eq!(presets.len(), 15);
        assert_eq!(VoicePreset::default_preset().id, "rachel");
        let river = presets.iter().find(|p| p.id == "river").unwrap();
        assert_eq!(river.provider_voice_id, "SAz9YHcvj6GT2YYXdXww");
        assert_eq!(river.provider, TtsProvider::ElevenLabs);
    }

    /// `TTSProvider` is persisted into settings and history that the two apps
    /// are meant to be able to read from each other.
    #[test]
    fn provider_serializes_with_the_swift_raw_values() {
        assert_eq!(
            serde_json::to_string(&TtsProvider::ElevenLabs).unwrap(),
            "\"elevenLabs\""
        );
        assert_eq!(
            serde_json::to_string(&TtsProvider::OpenAI).unwrap(),
            "\"openAI\""
        );
        assert_eq!(
            serde_json::to_string(&TtsProvider::SystemNative).unwrap(),
            "\"macOSNative\""
        );
    }
}
