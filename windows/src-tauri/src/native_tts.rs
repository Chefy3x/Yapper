//! The OS voice — counterpart of `Yapper/Services/NativeTTSSpeaker.swift`
//! (`AVSpeechSynthesizer` there, WinRT `SpeechSynthesizer` here).
//!
//! Used when no cloud provider is configured, when the network is down, or when
//! a provider errors out on the first segment.
//!
//! **Structural divergence from the Mac app, on purpose.** Swift models the
//! native voice as a *second engine* (`TTSCoordinator.Engine.native`) that
//! speaks the whole text at once and therefore has no scrubber, no transcript
//! and no seek. WinRT hands back a complete WAV stream rather than driving the
//! speakers itself, so here the native voice is just another
//! [`SpeechSynthesizing`] implementation and rides the same [`StreamPlayer`] as
//! ElevenLabs and OpenAI. The deck behaves identically offline — one transport
//! instead of two special cases.
//!
//! [`StreamPlayer`]: crate::pipeline::player::StreamPlayer

use crate::models::{TtsProvider, VoicePreset};
use crate::pipeline::synthesizer::{
    SpeechSegment, SpeechSynthesizing, SynthError, SynthFuture, SynthesisRequest,
};

/// Speaks with the system voice. `voice_id` is a WinRT voice id; empty means
/// "whatever Windows considers the default voice".
pub struct NativeSynthesizer {
    pub voice_id: String,
}

impl NativeSynthesizer {
    pub fn new(voice_id: impl Into<String>) -> Self {
        Self {
            voice_id: voice_id.into(),
        }
    }
}

impl SpeechSynthesizing for NativeSynthesizer {
    /// The conditioning arguments are accepted and dropped: the OS voice has no
    /// concept of stitching or neighbour context.
    fn synthesize<'a>(&'a self, req: SynthesisRequest<'a>) -> SynthFuture<'a> {
        let text = req.text.to_string();
        let voice_id = self.voice_id.clone();
        Box::pin(async move {
            let data = imp::synthesize(&text, &voice_id)
                .await
                .map_err(SynthError::from)?;
            Ok(SpeechSegment {
                data,
                request_id: None,
            })
        })
    }
}

/// One installed system voice, as WinRT reports it.
#[derive(Clone, Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SystemVoice {
    pub id: String,
    pub display_name: String,
    pub language: String,
}

/// Installed system voices as selectable presets.
///
/// Their ids are namespaced `system:<winrt id>` because, unlike the fixed
/// cross-platform catalog, this list is whatever a given PC happens to have
/// installed — the prefix is what lets [`crate::settings::SettingsStore`]
/// resolve one without carrying a copy of the machine's voice list.
pub const SYSTEM_PREFIX: &str = "system:";

pub fn system_presets() -> Vec<VoicePreset> {
    system_voices()
        .into_iter()
        .map(|v| VoicePreset {
            id: format!("{SYSTEM_PREFIX}{}", v.id),
            display_name: v.display_name,
            provider: TtsProvider::SystemNative,
            provider_voice_id: v.id,
            language: v.language,
            is_custom: false,
        })
        .collect()
}

/// Resolve a `system:`-prefixed id without touching WinRT — the voice id is
/// carried in the string itself, so a preset survives the voice being
/// uninstalled (Windows just falls back to its default).
pub fn preset_for_id(id: &str) -> Option<VoicePreset> {
    let winrt_id = id.strip_prefix(SYSTEM_PREFIX)?;
    let display_name = system_voices()
        .into_iter()
        .find(|v| v.id == winrt_id)
        .map(|v| v.display_name)
        .unwrap_or_else(|| "Windows voice".to_string());
    Some(VoicePreset {
        id: id.to_string(),
        display_name,
        provider: TtsProvider::SystemNative,
        provider_voice_id: winrt_id.to_string(),
        language: "en".into(),
        is_custom: false,
    })
}

#[cfg(windows)]
mod imp {
    use super::SystemVoice;
    use windows::core::HSTRING;
    use windows::Media::SpeechSynthesis::SpeechSynthesizer;
    use windows::Storage::Streams::DataReader;

    /// Synthesize to a complete WAV buffer. WinRT gives us a
    /// `SpeechSynthesisStream`, which is a RIFF/WAV payload — the same shape
    /// `audio::decode` already handles for MP3.
    ///
    /// The WinRT async types implement `IntoFuture`, and every object touched
    /// here is agile (`unsafe impl Send` in the generated bindings), so this
    /// awaits inline on the tokio worker instead of blocking a thread.
    pub async fn synthesize(text: &str, voice_id: &str) -> Result<Vec<u8>, String> {
        let synth = SpeechSynthesizer::new().map_err(|e| e.to_string())?;

        if !voice_id.is_empty() {
            // Scoped so the collection is dropped before the first await.
            let voices = SpeechSynthesizer::AllVoices().map_err(|e| e.to_string())?;
            for voice in &voices {
                if voice.Id().map(|id| id.to_string()).as_deref() == Ok(voice_id) {
                    synth.SetVoice(&voice).map_err(|e| e.to_string())?;
                    break;
                }
            }
        }

        let stream = synth
            .SynthesizeTextToStreamAsync(&HSTRING::from(text))
            .map_err(|e| e.to_string())?
            .await
            .map_err(|e| e.to_string())?;

        let size = stream.Size().map_err(|e| e.to_string())?;
        if size == 0 {
            return Err("the system voice produced no audio".into());
        }
        // `IInputStream` is one of the few types here that is NOT agile, so it
        // must not be alive across the await below or this future stops being
        // `Send` and can't ride the pipeline. Scoped so it drops with the block.
        let reader = {
            let input = stream.GetInputStreamAt(0).map_err(|e| e.to_string())?;
            DataReader::CreateDataReader(&input).map_err(|e| e.to_string())?
        };
        reader
            .LoadAsync(size as u32)
            .map_err(|e| e.to_string())?
            .await
            .map_err(|e| e.to_string())?;

        let mut buf = vec![0u8; size as usize];
        reader.ReadBytes(&mut buf).map_err(|e| e.to_string())?;
        Ok(buf)
    }

    pub fn voices() -> Vec<SystemVoice> {
        let Ok(all) = SpeechSynthesizer::AllVoices() else {
            return Vec::new();
        };
        all.into_iter()
            .filter_map(|v| {
                Some(SystemVoice {
                    id: v.Id().ok()?.to_string(),
                    display_name: v.DisplayName().ok()?.to_string(),
                    language: v.Language().ok()?.to_string(),
                })
            })
            .collect()
    }
}

#[cfg(not(windows))]
mod imp {
    use super::SystemVoice;

    /// Mac-side development builds have no WinRT. Failing loudly here is
    /// deliberate: a silent stub would let the fallback path "pass" on the
    /// development machine and only break on the target OS.
    pub async fn synthesize(_text: &str, _voice_id: &str) -> Result<Vec<u8>, String> {
        Err("the system voice is only available on Windows".into())
    }

    pub fn voices() -> Vec<SystemVoice> {
        Vec::new()
    }
}

/// Every system voice Windows has installed.
pub fn system_voices() -> Vec<SystemVoice> {
    imp::voices()
}
