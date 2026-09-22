//! Owns the active playback session — port of
//! `Yapper/Services/TTSCoordinator.swift`.
//!
//! Picks a provider for the chosen voice, streams the audio, keeps the
//! Conversation Mode queue, and records finished reads into History.
//!
//! Divergence from the Swift original: there is no separate `Engine.native`
//! case. The OS voice is a [`SpeechSynthesizing`] implementation here (see
//! [`crate::native_tts`]), so every path — cloud, offline, replay — runs through
//! one [`StreamPlayer`]. Falling back to the system voice therefore keeps the
//! scrubber, transcript, and speed controls, which the Mac app loses.

use std::collections::VecDeque;
use std::path::Path;
use std::sync::{Arc, Mutex};

use crate::audio::AudioSink;
use crate::credentials::{self, Account};
use crate::history::{HistoryStore, Origin};
use crate::models::{ElevenLabsModel, ReadingItem, TtsProvider, VoicePreset};
use crate::native_tts::NativeSynthesizer;
use crate::paths;
use crate::pipeline::elevenlabs::VoiceSettings;
use crate::pipeline::player::{PlayerState, Snapshot, StreamPlayer};
use crate::pipeline::segmentation;
use crate::pipeline::synthesizer::{ElevenLabsSynthesizer, OpenAISynthesizer, SpeechSynthesizing};
use crate::settings::SettingsStore;

struct QueueItem {
    item: ReadingItem,
    voice: VoicePreset,
}

#[derive(Default)]
struct State {
    active: Option<Arc<StreamPlayer>>,
    queue: VecDeque<QueueItem>,
}

pub struct Coordinator {
    sink: Arc<dyn AudioSink>,
    settings: Arc<Mutex<SettingsStore>>,
    history: Arc<Mutex<HistoryStore>>,
    state: Mutex<State>,
}

impl Coordinator {
    pub fn new(
        sink: Arc<dyn AudioSink>,
        settings: Arc<Mutex<SettingsStore>>,
        history: Arc<Mutex<HistoryStore>>,
    ) -> Arc<Self> {
        Arc::new(Self {
            sink,
            settings,
            history,
            state: Mutex::new(State::default()),
        })
    }

    // MARK: - Transport

    pub fn snapshot(&self) -> Option<Snapshot> {
        self.state
            .lock()
            .unwrap()
            .active
            .as_ref()
            .map(|p| p.snapshot())
    }

    pub fn queue_count(&self) -> usize {
        self.state.lock().unwrap().queue.len()
    }

    pub fn is_playing(&self) -> bool {
        self.state
            .lock()
            .unwrap()
            .active
            .as_ref()
            .is_some_and(|p| p.is_active())
    }

    /// Pause / resume whichever read is active. Called from a hotkey tap.
    pub fn pause_or_resume(&self) {
        let player = self.state.lock().unwrap().active.clone();
        let Some(player) = player else { return };
        match player.state() {
            PlayerState::Playing => player.pause(),
            PlayerState::Paused => player.resume(),
            _ => {}
        }
    }

    pub fn seek(&self, seconds: f64) {
        if let Some(p) = self.state.lock().unwrap().active.clone() {
            p.seek(seconds);
        }
    }

    /// Persist the chosen speed so it sticks across reads, then apply it.
    pub fn set_rate(&self, rate: f32) {
        self.settings
            .lock()
            .unwrap()
            .update(|s| s.playback_rate = rate as f64);
        if let Some(p) = self.state.lock().unwrap().active.clone() {
            p.set_rate(rate);
        }
    }

    /// The deck's single speed button: 1× → 1.25× → … → 2× → 1×.
    pub fn cycle_rate(&self) {
        let player = self.state.lock().unwrap().active.clone();
        let Some(player) = player else { return };
        player.cycle_rate();
        let rate = player.snapshot().rate as f64;
        self.settings
            .lock()
            .unwrap()
            .update(|s| s.playback_rate = rate);
    }

    pub fn step_rate(&self, up: bool) {
        let player = self.state.lock().unwrap().active.clone();
        let Some(player) = player else { return };
        player.step_rate(up);
        let rate = player.snapshot().rate as f64;
        self.settings
            .lock()
            .unwrap()
            .update(|s| s.playback_rate = rate);
    }

    /// Drive the active player's clock. The Tauri layer calls this ~10x/second.
    pub fn tick(&self) {
        if let Some(p) = self.state.lock().unwrap().active.clone() {
            p.tick();
        }
    }

    pub fn stop(&self) {
        self.stop_active_only();
        self.clear_queue();
    }

    /// Stop the active engine without touching the queue (used by skip-to-next).
    fn stop_active_only(&self) {
        let player = self.state.lock().unwrap().active.take();
        if let Some(p) = player {
            p.stop();
        }
    }

    // MARK: - Conversation Mode queue

    /// Append a response to the FIFO queue. Starts immediately only if nothing
    /// is playing; otherwise it plays after the current item finishes — so reads
    /// never overlap.
    ///
    /// Unused until Phase 3: nothing produces conversation items until the UIA
    /// reader can watch an app for new assistant messages. The queue itself is
    /// finished and tested, so that phase only has to call this.
    #[allow(dead_code)]
    pub fn enqueue(self: &Arc<Self>, item: ReadingItem, voice: VoicePreset) {
        {
            let mut state = self.state.lock().unwrap();
            state.queue.push_back(QueueItem { item, voice });
            if state.active.is_some() {
                return;
            }
        }
        self.start_next_from_queue();
    }

    /// Skip the current item and play the next queued one (or go idle if the
    /// queue is empty).
    pub fn skip_to_next(self: &Arc<Self>) {
        self.stop_active_only();
        self.start_next_from_queue();
    }

    pub fn clear_queue(&self) {
        self.state.lock().unwrap().queue.clear();
    }

    fn start_next_from_queue(self: &Arc<Self>) {
        let next = {
            let mut state = self.state.lock().unwrap();
            if state.active.is_some() {
                return;
            }
            state.queue.pop_front()
        };
        let Some(next) = next else { return };
        let audio_file = self.speak_internal(&next.item.cleaned_text, &next.voice, true);
        self.record(&next.item, &next.voice, audio_file, Origin::Conversation);
    }

    // MARK: - Speaking

    /// Preview a voice with a fixed sample line. Used by the Voices tab.
    pub fn preview(self: &Arc<Self>, voice: &VoicePreset) {
        let sample = format!(
            "Hi, I'm {}. This is Yapper reading aloud.",
            voice.display_name
        );
        self.speak(&sample, voice);
    }

    /// Manual read (Read Latest / Selection / preview). Supersedes any
    /// conversation queue. Returns the cache file name once streaming starts, so
    /// History can reference it for replay.
    pub fn speak(self: &Arc<Self>, text: &str, voice: &VoicePreset) -> Option<String> {
        self.stop(); // stops the active engine AND clears the conversation queue
        self.speak_internal(text, voice, false)
    }

    /// Read `item` and file it in History under `origin`.
    pub fn read(self: &Arc<Self>, item: &ReadingItem, voice: &VoicePreset, origin: Origin) {
        let audio_file = self.speak(&item.cleaned_text, voice);
        self.record(item, voice, audio_file, origin);
    }

    fn record(
        &self,
        item: &ReadingItem,
        voice: &VoicePreset,
        audio: Option<String>,
        origin: Origin,
    ) {
        let mut history = self.history.lock().unwrap();
        history.record(item, &voice.id, audio, origin);
        let retention = self.settings.lock().unwrap().get().history_retention_hours;
        history.prune(retention);
    }

    fn speak_internal(
        self: &Arc<Self>,
        text: &str,
        voice: &VoicePreset,
        advance_on_finish: bool,
    ) -> Option<String> {
        let segments = segmentation::segments(text);
        if segments.is_empty() {
            return None;
        }

        let (synthesizer, is_native) = self.synthesizer_for(voice);
        log::info!(
            "speak decision: voice={} provider={:?} → engine={}",
            voice.display_name,
            voice.provider,
            if is_native { "system" } else { "cloud" }
        );

        self.warn_if_over_character_limit(text, voice);

        // The native voice produces no shareable clip worth caching for replay
        // — it costs nothing to regenerate — so only cloud reads get a file.
        let file_name = (!is_native).then(|| format!("{}.mp3", uuid::Uuid::new_v4()));
        let cache_path = file_name
            .as_ref()
            .map(|n| paths::cache_dir().join(n))
            .unwrap_or_else(|| paths::cache_dir().join("native.tmp"));

        let player = StreamPlayer::new(segments, synthesizer, self.sink.clone(), cache_path);
        let rate = self.settings.lock().unwrap().get().playback_rate as f32;
        player.set_rate(rate); // start at the user's last-chosen speed

        let me = Arc::downgrade(self);
        player.set_on_finish(Box::new(move || {
            let Some(me) = me.upgrade() else { return };
            me.state.lock().unwrap().active = None;
            if advance_on_finish {
                me.start_next_from_queue();
            }
        }));

        if !is_native {
            // Couldn't synthesize the first segment — fall back to the system
            // voice rather than leaving the user with silence.
            let me = Arc::downgrade(self);
            let text = text.to_string();
            let voice = voice.clone();
            player.set_on_failure(Box::new(move || {
                let Some(me) = me.upgrade() else { return };
                log::error!(
                    "{:?} synth failed; falling back to the system voice.",
                    voice.provider
                );
                me.state.lock().unwrap().active = None;
                let mut fallback = voice.clone();
                fallback.provider = TtsProvider::SystemNative;
                fallback.provider_voice_id = String::new();
                me.speak_internal(&text, &fallback, advance_on_finish);
            }));
        }

        self.state.lock().unwrap().active = Some(player.clone());
        player.start();
        file_name
    }

    /// Replay an already-synthesized clip straight from the cache — no network
    /// call. `text` only populates the transcript; playback comes from the file.
    pub fn replay(self: &Arc<Self>, file: &Path, text: &str) {
        self.stop();
        let Ok(player) = StreamPlayer::replay(file, text.to_string(), self.sink.clone()) else {
            log::error!("Replay failed: {} is unreadable", file.display());
            return;
        };
        let rate = self.settings.lock().unwrap().get().playback_rate as f32;
        player.set_rate(rate);
        let me = Arc::downgrade(self);
        player.set_on_finish(Box::new(move || {
            if let Some(me) = me.upgrade() {
                me.state.lock().unwrap().active = None;
            }
        }));
        self.state.lock().unwrap().active = Some(player.clone());
        player.start();
    }

    // MARK: - Engine choice

    /// The streaming engine for this voice. A provider with no stored key falls
    /// through to the system voice, which is why an unconfigured install
    /// degrades instead of failing. Returns `(engine, is_native)`.
    fn synthesizer_for(&self, voice: &VoicePreset) -> (Arc<dyn SpeechSynthesizing>, bool) {
        let settings = self.settings.lock().unwrap();
        match voice.provider {
            TtsProvider::ElevenLabs => match credentials::get(Account::ElevenLabsKey) {
                Some(key) => (
                    Arc::new(ElevenLabsSynthesizer {
                        voice_id: voice.provider_voice_id.clone(),
                        model_id: settings.get().eleven_labs_model_id.clone(),
                        output_format: "mp3_44100_128".into(),
                        voice_settings: VoiceSettings::natural(),
                        api_key: key,
                    }),
                    false,
                ),
                None => (Arc::new(NativeSynthesizer::new("")), true),
            },
            TtsProvider::OpenAI => match credentials::get(Account::OpenAIKey) {
                Some(key) => (
                    Arc::new(OpenAISynthesizer {
                        voice: voice.provider_voice_id.clone(),
                        model_id: settings.get().open_ai_model_id.clone(),
                        api_key: key,
                    }),
                    false,
                ),
                None => (Arc::new(NativeSynthesizer::new("")), true),
            },
            TtsProvider::SystemNative => (
                Arc::new(NativeSynthesizer::new(voice.provider_voice_id.clone())),
                true,
            ),
        }
    }

    /// Soft character-limit check: log if we're over the model's per-request
    /// ceiling. ElevenLabs may reject or truncate; we send anyway rather than
    /// silently refusing to read something.
    fn warn_if_over_character_limit(&self, text: &str, voice: &VoicePreset) {
        if voice.provider != TtsProvider::ElevenLabs {
            return;
        }
        let settings = self.settings.lock().unwrap();
        let Some(model) = ElevenLabsModel::parse(&settings.get().eleven_labs_model_id) else {
            return;
        };
        let count = text.chars().count();
        if count > model.character_limit() {
            log::warn!(
                "Text is {count} chars but {} limit is {}. Sending anyway — ElevenLabs may reject or truncate.",
                model.display_name(),
                model.character_limit()
            );
        }
    }
}
