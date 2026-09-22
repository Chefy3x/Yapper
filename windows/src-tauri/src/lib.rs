//! Yapper for Windows — Tauri backend.
//!
//! Module map, and how it lines up with the Mac app:
//!
//! | here | `Yapper/…` |
//! |---|---|
//! | `pipeline` | `Services/SentenceStreamPlayer`, `ElevenLabsClient`, `OpenAIClient`, `TextCleaner` |
//! | `coordinator` | `Services/TTSCoordinator` |
//! | `history` / `settings` | `Services/HistoryStore`, `SettingsStore` |
//! | `credentials` | `Services/Keychain` |
//! | `native_tts` | `Services/NativeTTSSpeaker` |
//! | `shortcuts` | `Services/HotkeyManager` |
//! | `audio` | the `AVAudioPlayer` half of the stream player |
//! | `reader` | `Services/AccessibilityReader` — **Phase 3, Windows-only** |

mod audio;
mod coordinator;
mod credentials;
mod history;
mod models;
mod native_tts;
mod paths;
mod pipeline;
#[cfg(windows)]
mod reader;
mod settings;
mod shortcuts;

use std::sync::{Arc, Mutex};
use std::time::Duration;

use tauri::{Emitter, Manager};

use coordinator::Coordinator;
use credentials::Account;
use history::{HistoryEntry, HistoryStore, Origin};
use models::{ElevenLabsModel, ReadingItem, VoicePreset};
use pipeline::player::{Snapshot, AVAILABLE_RATES};
use settings::{Settings, SettingsStore};

pub struct AppState {
    coordinator: Arc<Coordinator>,
    settings: Arc<Mutex<SettingsStore>>,
    history: Arc<Mutex<HistoryStore>>,
}

type CmdResult<T> = Result<T, String>;

// MARK: - Transport

#[tauri::command]
fn player_snapshot(state: tauri::State<AppState>) -> Option<Snapshot> {
    state.coordinator.snapshot()
}

/// Returns the one-line preview of what is now being read, for the deck header.
#[tauri::command]
fn speak(text: String, state: tauri::State<AppState>) -> CmdResult<String> {
    let cleaned = pipeline::text_cleaner::clean(&text);
    if cleaned.is_empty() {
        return Err("There's nothing readable in that.".into());
    }
    let voice = state.settings.lock().unwrap().active_voice();
    let item = ReadingItem::make("Yapper", cleaned, text);
    let preview = item.preview();
    state.coordinator.read(&item, &voice, Origin::Selection);
    Ok(preview)
}

#[tauri::command]
fn pause_or_resume(state: tauri::State<AppState>) {
    state.coordinator.pause_or_resume();
}

#[tauri::command]
fn stop(state: tauri::State<AppState>) {
    state.coordinator.stop();
}

#[tauri::command]
fn seek(seconds: f64, state: tauri::State<AppState>) {
    state.coordinator.seek(seconds);
}

#[tauri::command]
fn set_rate(rate: f32, state: tauri::State<AppState>) {
    state.coordinator.set_rate(rate);
}

#[tauri::command]
fn step_rate(up: bool, state: tauri::State<AppState>) {
    state.coordinator.step_rate(up);
}

#[tauri::command]
fn cycle_rate(state: tauri::State<AppState>) {
    state.coordinator.cycle_rate();
}

#[tauri::command]
fn available_rates() -> Vec<f32> {
    AVAILABLE_RATES.to_vec()
}

#[tauri::command]
fn queue_count(state: tauri::State<AppState>) -> usize {
    state.coordinator.queue_count()
}

// MARK: - Reading (Phase 3)

/// Both reading entry points exist so the UI and hotkeys can be wired and
/// exercised now; they report the Phase 3 gap instead of pretending to work.
#[tauri::command]
fn read_latest(_state: tauri::State<AppState>) -> CmdResult<()> {
    #[cfg(windows)]
    {
        reader::read_latest().map(|_| ()).map_err(|e| e.to_string())
    }
    #[cfg(not(windows))]
    Err("Reading from other apps is Windows-only.".into())
}

#[tauri::command]
fn read_selection(_state: tauri::State<AppState>) -> CmdResult<()> {
    #[cfg(windows)]
    {
        reader::read_selection()
            .map(|_| ())
            .map_err(|e| e.to_string())
    }
    #[cfg(not(windows))]
    Err("Reading from other apps is Windows-only.".into())
}

// MARK: - Settings & voices

/// Whether to show the first-run guide. False for anyone upgrading into this
/// version — shipping a setup wizard to someone already using the app would be
/// worse than shipping them nothing.
#[tauri::command]
fn should_show_onboarding(state: tauri::State<AppState>) -> bool {
    state.settings.lock().unwrap().looks_like_first_run()
}

#[tauri::command]
fn get_settings(state: tauri::State<AppState>) -> Settings {
    state.settings.lock().unwrap().get().clone()
}

#[tauri::command]
fn save_settings(next: Settings, state: tauri::State<AppState>) -> Settings {
    let mut store = state.settings.lock().unwrap();
    store.update(|s| *s = next);
    store.get().clone()
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct VoiceCatalog {
    presets: Vec<VoicePreset>,
    custom: Vec<VoicePreset>,
    system: Vec<VoicePreset>,
    eleven_labs_models: Vec<ModelOption>,
    open_ai_models: Vec<ModelOption>,
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct ModelOption {
    id: String,
    display_name: String,
    /// The one-line "why you'd pick this" the settings pane shows.
    blurb: String,
}

#[tauri::command]
fn list_voices(state: tauri::State<AppState>) -> VoiceCatalog {
    VoiceCatalog {
        presets: VoicePreset::presets(),
        custom: state.settings.lock().unwrap().get().custom_voices.clone(),
        system: native_tts::system_presets(),
        eleven_labs_models: ElevenLabsModel::ALL
            .iter()
            .map(|m| ModelOption {
                id: m.as_str().into(),
                display_name: m.display_name().into(),
                // The Mac enum carries the limit rather than prose; say the
                // thing that actually decides the choice.
                blurb: format!("Up to {} characters per request.", m.character_limit()),
            })
            .collect(),
        open_ai_models: pipeline::openai::Model::ALL
            .iter()
            .map(|m| ModelOption {
                id: m.as_str().into(),
                display_name: m.display_name().into(),
                blurb: m.blurb().into(),
            })
            .collect(),
    }
}

#[tauri::command]
fn preview_voice(voice_id: String, state: tauri::State<AppState>) -> CmdResult<()> {
    let voice = match native_tts::preset_for_id(&voice_id) {
        Some(system) => system,
        None => VoicePreset::presets()
            .into_iter()
            .chain(state.settings.lock().unwrap().get().custom_voices.clone())
            .find(|v| v.id == voice_id)
            .ok_or_else(|| format!("No voice with id {voice_id}"))?,
    };
    state.coordinator.preview(&voice);
    Ok(())
}

// MARK: - Credentials

fn account(provider: &str) -> CmdResult<Account> {
    match provider {
        "elevenLabs" => Ok(Account::ElevenLabsKey),
        "openAI" => Ok(Account::OpenAIKey),
        other => Err(format!("Unknown provider {other}")),
    }
}

#[tauri::command]
fn set_api_key(provider: String, key: String) -> CmdResult<()> {
    let account = account(&provider)?;
    let trimmed = key.trim();
    let ok = if trimmed.is_empty() {
        credentials::remove(account)
    } else {
        credentials::set(trimmed, account)
    };
    ok.then_some(())
        .ok_or_else(|| "Windows refused to store the key.".into())
}

#[tauri::command]
fn has_api_key(provider: String) -> CmdResult<bool> {
    Ok(credentials::has_key(account(&provider)?))
}

// MARK: - History

/// A History row as the deck draws it. Separate from [`HistoryEntry`] on
/// purpose: `history.json` keeps the exact shape the Swift store writes, so the
/// derived fields the list needs live here instead of in the file.
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct HistoryRow {
    #[serde(flatten)]
    entry: HistoryEntry,
    /// Truncated one-liner, computed by the ported logic rather than re-done in JS.
    preview: String,
    origin_label: &'static str,
    /// The clip is still on disk, so replay is instant rather than re-synthesized.
    has_audio: bool,
}

#[tauri::command]
fn list_history(state: tauri::State<AppState>) -> Vec<HistoryRow> {
    let history = state.history.lock().unwrap();
    history
        .entries()
        .iter()
        .map(|e| HistoryRow {
            preview: e.preview(),
            origin_label: e.origin.label(),
            has_audio: history.audio_path(e).is_some(),
            entry: e.clone(),
        })
        .collect()
}

#[tauri::command]
fn replay(id: String, state: tauri::State<AppState>) -> CmdResult<()> {
    let (path, text) = {
        let history = state.history.lock().unwrap();
        let entry = history
            .entries()
            .iter()
            .find(|e| e.id == id)
            .ok_or("That read is no longer in History.")?;
        (history.audio_path(entry), entry.cleaned_text.clone())
    };
    match path {
        // Instant replay from the cache — no network call.
        Some(path) => state.coordinator.replay(&path, &text),
        // The clip has been pruned; re-synthesize from the stored text.
        None => {
            let voice = state.settings.lock().unwrap().active_voice();
            state.coordinator.speak(&text, &voice);
        }
    }
    Ok(())
}

#[tauri::command]
fn delete_history_entry(id: String, state: tauri::State<AppState>) {
    state.history.lock().unwrap().remove(&id);
}

#[tauri::command]
fn clear_history(state: tauri::State<AppState>) {
    state.history.lock().unwrap().clear_all();
}

// MARK: - Dev deck

/// Segment text exactly like the macOS pipeline does. Kept from Phase 1 so
/// segmentation can still be eyeballed against the Mac deck.
#[tauri::command]
fn segment_text(text: String) -> Vec<String> {
    pipeline::segmentation::segments(&text)
}

/// Clean markdown exactly like the macOS pipeline does — the other half of the
/// parity check, and the thing that decides what actually gets spoken.
#[tauri::command]
fn clean_text(text: String) -> String {
    pipeline::text_cleaner::clean(&text)
}

// MARK: - Setup

fn build_tray(app: &tauri::AppHandle) -> tauri::Result<()> {
    use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
    use tauri::tray::TrayIconBuilder;

    let open = MenuItem::with_id(app, "open", "Open Yapper", true, None::<&str>)?;
    let play = MenuItem::with_id(app, "play", "Play / Pause", true, None::<&str>)?;
    let stop_item = MenuItem::with_id(app, "stop", "Stop", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit Yapper", true, None::<&str>)?;
    let menu = Menu::with_items(
        app,
        &[
            &open,
            &PredefinedMenuItem::separator(app)?,
            &play,
            &stop_item,
            &PredefinedMenuItem::separator(app)?,
            &quit,
        ],
    )?;

    TrayIconBuilder::with_id("yapper")
        .icon(app.default_window_icon().cloned().expect("bundled icon"))
        .tooltip("Yapper — reads AI responses aloud")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| {
            let state = app.state::<AppState>();
            match event.id().as_ref() {
                "open" => shortcuts::show_deck(app),
                "play" => state.coordinator.pause_or_resume(),
                "stop" => state.coordinator.stop(),
                "quit" => app.exit(0),
                _ => {}
            }
        })
        .on_tray_icon_event(|tray, event| {
            use tauri::tray::{MouseButton, MouseButtonState, TrayIconEvent};
            // Left-click opens the deck; the menu is on right-click, matching
            // how Windows tray apps behave.
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                shortcuts::show_deck(tray.app_handle());
            }
        })
        .build(app)?;
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let app_dir = paths::app_dir();
    let settings = Arc::new(Mutex::new(SettingsStore::new(&app_dir)));
    let history = Arc::new(Mutex::new(HistoryStore::new(&app_dir, &paths::cache_dir())));

    // A machine with no usable output device still runs the pipeline and fills
    // History; it just makes no sound. Better than refusing to start.
    let sink: Arc<dyn audio::AudioSink> = match audio::rodio_sink::RodioSink::new() {
        Ok(s) => Arc::new(s),
        Err(e) => {
            log::error!("No audio output ({e}); running silent.");
            Arc::new(audio::null_sink::NullSink::new())
        }
    };

    let coordinator = Coordinator::new(sink, settings.clone(), history.clone());

    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .manage(AppState {
            coordinator,
            settings,
            history,
        })
        .setup(|app| {
            build_tray(app.handle())?;

            shortcuts::install(app.handle(), |app, action| {
                use shortcuts::Action;
                let state = app.state::<AppState>();
                match action {
                    // One key for both, exactly like the Mac tap: it toggles a
                    // read in progress and starts one otherwise.
                    Action::ReadLatestOrToggle => {
                        if state.coordinator.is_playing() {
                            state.coordinator.pause_or_resume();
                        } else if let Err(e) = read_latest(state) {
                            log::warn!("Read latest: {e}");
                        }
                    }
                    Action::ReadSelection => {
                        if let Err(e) = read_selection(state) {
                            log::warn!("Read selection: {e}");
                        }
                    }
                    Action::ToggleConversationMode => {
                        let settings = state.settings.clone();
                        let mut store = settings.lock().unwrap();
                        let now = !store.get().conversation_default_on;
                        store.update(|s| s.conversation_default_on = now);
                        let _ = app.emit("conversation-mode", now);
                    }
                    Action::SkipNext => state.coordinator.skip_to_next(),
                }
            });

            // One clock for the whole transport: advance the player and push a
            // snapshot to the deck. 10 Hz is the cadence the Mac scrubber uses.
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                let mut ticker = tokio::time::interval(Duration::from_millis(100));
                loop {
                    ticker.tick().await;
                    let state = handle.state::<AppState>();
                    state.coordinator.tick();
                    if let Some(snapshot) = state.coordinator.snapshot() {
                        let _ = handle.emit("player", snapshot);
                    }
                }
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            player_snapshot,
            speak,
            pause_or_resume,
            stop,
            seek,
            set_rate,
            step_rate,
            cycle_rate,
            available_rates,
            queue_count,
            read_latest,
            read_selection,
            should_show_onboarding,
            get_settings,
            save_settings,
            list_voices,
            preview_voice,
            set_api_key,
            has_api_key,
            list_history,
            replay,
            delete_history_entry,
            clear_history,
            segment_text,
            clean_text,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
