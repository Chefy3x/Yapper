//! User preferences — port of `Yapper/SettingsStore.swift`.
//!
//! Windows has no `UserDefaults`, so this persists to `settings.json` beside
//! `history.json`. Field names match the Swift `Key` enum, so the two files line
//! up when someone reads both. Sensitive material (API keys) never lands here —
//! it lives in the credential store (see `credentials`).

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::models::{ElevenLabsModel, VoicePreset};
use crate::pipeline::openai;

/// Bounds for the cassette deck size multiplier — one source of truth shared by
/// the Settings slider and window edge-resizing. The 0.75 floor keeps the deck
/// from shrinking narrower than the minimal player; below that the transport and
/// scrubber get too small to hit.
pub const CASSETTE_SCALE_RANGE: (f64, f64) = (0.75, 1.6);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MiniPlayerCorner {
    BottomRight,
    BottomLeft,
    TopRight,
    TopLeft,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MiniPlayerTheme {
    Minimal,
    Cassette,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    pub active_voice_id: String,
    pub conversation_default_on: bool,
    /// Executable names Conversation Mode watches for new assistant responses.
    /// The Mac app stores bundle IDs here; the Windows reader keys off process
    /// names instead, so the values differ by platform even though the setting
    /// does the same job.
    pub conversation_allowlist: Vec<String>,
    pub history_retention_hours: i64,
    pub use_native_voice_offline: bool,
    pub eleven_labs_model_id: String,
    pub open_ai_model_id: String,
    /// Last-used playback speed (1.0 = normal). Persists so a chosen speed
    /// sticks across reads instead of resetting to 1× every time.
    pub playback_rate: f64,
    pub custom_voices: Vec<VoicePreset>,
    pub mini_player_default_corner: MiniPlayerCorner,
    pub mini_player_theme: MiniPlayerTheme,
    /// Cassette deck size multiplier (1.0 = the design size).
    pub cassette_scale: f64,
    pub launch_at_login: bool,
    /// The first-run guide has been seen (or explicitly skipped). Never shown
    /// again once true.
    pub onboarding_completed: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            active_voice_id: VoicePreset::default_preset().id,
            conversation_default_on: false,
            // Default to the apps with the most reliable read strategies. Filled
            // in with real process names once the Phase 3 adapters exist.
            conversation_allowlist: vec!["Claude.exe".into()],
            history_retention_hours: 24,
            use_native_voice_offline: true,
            eleven_labs_model_id: ElevenLabsModel::DEFAULT.as_str().into(),
            open_ai_model_id: openai::Model::DEFAULT.as_str().into(),
            playback_rate: 1.0,
            custom_voices: Vec::new(),
            mini_player_default_corner: MiniPlayerCorner::BottomRight,
            mini_player_theme: MiniPlayerTheme::Minimal,
            cassette_scale: 1.0,
            launch_at_login: false,
            onboarding_completed: false,
        }
    }
}

pub struct SettingsStore {
    path: PathBuf,
    settings: Settings,
    /// Nothing had ever been persisted when this store was opened — a genuinely
    /// fresh install. Guards the first-run guide against firing for people who
    /// upgrade into this version: shipping them a setup wizard for an app they
    /// already use would be worse than shipping them nothing.
    looked_like_first_run: bool,
}

impl SettingsStore {
    pub fn new(dir: &Path) -> Self {
        let _ = std::fs::create_dir_all(dir);
        let path = dir.join("settings.json");
        let existing = std::fs::read(&path)
            .ok()
            .and_then(|d| serde_json::from_slice::<Settings>(&d).ok());
        let looked_like_first_run = existing.is_none();
        let mut store = Self {
            path,
            settings: existing.unwrap_or_default(),
            looked_like_first_run,
        };
        store.migrate();
        store
    }

    /// Deprecated `eleven_turbo_v2_5` → `eleven_flash_v2_5`, same migration the
    /// Swift store performs on load.
    fn migrate(&mut self) {
        if self.settings.eleven_labs_model_id == "eleven_turbo_v2_5" {
            self.settings.eleven_labs_model_id = ElevenLabsModel::FlashV25.as_str().into();
            self.save();
        }
    }

    pub fn get(&self) -> &Settings {
        &self.settings
    }

    pub fn looks_like_first_run(&self) -> bool {
        self.looked_like_first_run && !self.settings.onboarding_completed
    }

    /// Mutate and persist in one step, clamping the values that have bounds.
    pub fn update(&mut self, f: impl FnOnce(&mut Settings)) {
        f(&mut self.settings);
        let (lo, hi) = CASSETTE_SCALE_RANGE;
        self.settings.cassette_scale = self.settings.cassette_scale.clamp(lo, hi);
        self.settings.playback_rate = self.settings.playback_rate.clamp(1.0, 2.0);
        self.settings.history_retention_hours = self.settings.history_retention_hours.max(1);
        self.save();
    }

    /// The voice the user has chosen, from the built-in catalog or their own
    /// custom entries. Falls back to the default preset if the stored id no
    /// longer resolves — e.g. a custom voice that was deleted.
    pub fn active_voice(&self) -> VoicePreset {
        let id = &self.settings.active_voice_id;
        if let Some(system) = crate::native_tts::preset_for_id(id) {
            return system;
        }
        self.settings
            .custom_voices
            .iter()
            .chain(VoicePreset::presets().iter())
            .find(|v| &v.id == id)
            .cloned()
            .unwrap_or_else(VoicePreset::default_preset)
    }

    fn save(&self) {
        let Ok(data) = serde_json::to_vec_pretty(&self.settings) else {
            return;
        };
        let tmp = self.path.with_extension("json.tmp");
        if std::fs::write(&tmp, &data).is_ok() {
            let _ = std::fs::rename(&tmp, &self.path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> (SettingsStore, tempfile::TempDir) {
        let dir = tempfile::tempdir().unwrap();
        (SettingsStore::new(dir.path()), dir)
    }

    #[test]
    fn defaults_match_the_mac_app() {
        let (s, _d) = store();
        let d = s.get();
        assert_eq!(d.active_voice_id, "rachel");
        assert_eq!(d.history_retention_hours, 24);
        assert!(d.use_native_voice_offline);
        assert_eq!(d.eleven_labs_model_id, "eleven_flash_v2_5");
        assert_eq!(d.open_ai_model_id, "gpt-4o-mini-tts");
        assert_eq!(d.playback_rate, 1.0);
        assert_eq!(d.cassette_scale, 1.0);
    }

    #[test]
    fn settings_survive_a_restart() {
        let dir = tempfile::tempdir().unwrap();
        SettingsStore::new(dir.path()).update(|s| s.active_voice_id = "river".into());
        assert_eq!(
            SettingsStore::new(dir.path()).get().active_voice_id,
            "river"
        );
    }

    /// Mirrors the Swift store's `looksLikeFirstRun` guard: an existing install
    /// must never be shown the setup guide.
    #[test]
    fn only_a_pristine_install_looks_like_a_first_run() {
        let dir = tempfile::tempdir().unwrap();
        assert!(SettingsStore::new(dir.path()).looks_like_first_run());
        SettingsStore::new(dir.path()).update(|s| s.playback_rate = 1.5);
        assert!(!SettingsStore::new(dir.path()).looks_like_first_run());
    }

    #[test]
    fn the_deprecated_turbo_model_migrates_to_flash() {
        let dir = tempfile::tempdir().unwrap();
        SettingsStore::new(dir.path())
            .update(|s| s.eleven_labs_model_id = "eleven_turbo_v2_5".into());
        let migrated = SettingsStore::new(dir.path());
        assert_eq!(migrated.get().eleven_labs_model_id, "eleven_flash_v2_5");
    }

    #[test]
    fn bounded_values_are_clamped_on_write() {
        let (mut s, _d) = store();
        s.update(|v| {
            v.cassette_scale = 99.0;
            v.playback_rate = 0.1;
        });
        assert_eq!(s.get().cassette_scale, CASSETTE_SCALE_RANGE.1);
        assert_eq!(s.get().playback_rate, 1.0);
    }

    /// A machine-specific system voice resolves from its id alone, so a voice
    /// that has since been uninstalled still picks the system engine (Windows
    /// substitutes its default) rather than silently reverting to ElevenLabs.
    #[test]
    fn a_system_voice_resolves_from_its_namespaced_id() {
        let (mut s, _d) = store();
        s.update(|v| v.active_voice_id = "system:MSTTS_V110_enUS_ZiraM".into());
        let voice = s.active_voice();
        assert_eq!(voice.provider, crate::models::TtsProvider::SystemNative);
        assert_eq!(voice.provider_voice_id, "MSTTS_V110_enUS_ZiraM");
    }

    #[test]
    fn a_deleted_custom_voice_falls_back_to_the_default() {
        let (mut s, _d) = store();
        s.update(|v| v.active_voice_id = "no-such-voice".into());
        assert_eq!(s.active_voice().id, "rachel");
    }

    #[test]
    fn custom_voices_win_over_the_catalog() {
        let (mut s, _d) = store();
        let mut mine = VoicePreset::default_preset();
        mine.id = "mine".into();
        mine.display_name = "Mine".into();
        mine.is_custom = true;
        s.update(|v| {
            v.custom_voices = vec![mine];
            v.active_voice_id = "mine".into();
        });
        assert_eq!(s.active_voice().display_name, "Mine");
    }
}
