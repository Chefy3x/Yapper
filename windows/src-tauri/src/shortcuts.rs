//! Global hotkeys — the counterpart of `Yapper/Services/HotkeyManager.swift`.
//!
//! ## What carries over, and what doesn't
//!
//! The Mac app's primary gesture is a *tap* of the right Command key: press and
//! release inside 400 ms with no other key, and Yapper reads the latest
//! response; hold it and it stays an ordinary modifier. That's implemented with
//! a `CGEventTap`, and it has no cross-platform equivalent — recognising it on
//! Windows means a `WH_KEYBOARD_LL` hook that watches for `VK_RMENU` /
//! `VK_RCONTROL` down-up pairs and swallows nothing. That's Phase 4's
//! Windows-only remainder, and the shape of it is:
//!
//! > On `WM_KEYDOWN` for `VK_RMENU` record the tick count; on `WM_KEYUP` fire
//! > only if no other key went down in between and the gap is under 400 ms.
//! > Pass every event through unchanged — the Mac tap deliberately never
//! > swallows the modifier, which is what lets right-Alt stay a normal key.
//!
//! Until then these are plain chords through `tauri-plugin-global-shortcut`,
//! which is the same set of *actions* bound to keys that work today. Anyone
//! coming from the Mac app gets every command; only the tap ergonomics are
//! missing.

use tauri::{AppHandle, Manager, Runtime};
use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut, ShortcutState};

/// The action a hotkey asks for. Named after the Mac app's callbacks so the two
/// hotkey tables read the same.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    ReadLatestOrToggle,
    ReadSelection,
    ToggleConversationMode,
    SkipNext,
}

impl Action {
    /// Default chords. Ctrl+Alt is used throughout because it is the least
    /// contested prefix on Windows: Win+key is reserved by the shell, and
    /// Ctrl+Shift collides with app shortcuts.
    pub fn default_shortcut(self) -> Shortcut {
        let ctrl_alt = Modifiers::CONTROL | Modifiers::ALT;
        match self {
            Action::ReadLatestOrToggle => Shortcut::new(Some(ctrl_alt), Code::KeyY),
            Action::ReadSelection => Shortcut::new(Some(ctrl_alt), Code::KeyS),
            Action::ToggleConversationMode => Shortcut::new(Some(ctrl_alt), Code::Enter),
            Action::SkipNext => Shortcut::new(Some(ctrl_alt), Code::ArrowRight),
        }
    }

    pub const ALL: [Action; 4] = [
        Action::ReadLatestOrToggle,
        Action::ReadSelection,
        Action::ToggleConversationMode,
        Action::SkipNext,
    ];

    pub fn label(self) -> &'static str {
        match self {
            Action::ReadLatestOrToggle => "Read latest / play-pause",
            Action::ReadSelection => "Read selection",
            Action::ToggleConversationMode => "Toggle Conversation Mode",
            Action::SkipNext => "Skip to next queued read",
        }
    }
}

/// Register every default chord. Failures are logged rather than fatal: a
/// shortcut another app already owns should cost you that one key, not the app.
pub fn install<R: Runtime>(
    app: &AppHandle<R>,
    on_action: impl Fn(&AppHandle<R>, Action) + Send + Sync + 'static,
) {
    let handler = std::sync::Arc::new(on_action);
    for action in Action::ALL {
        let shortcut = action.default_shortcut();
        let handler = handler.clone();
        let result = app
            .global_shortcut()
            .on_shortcut(shortcut, move |app, _shortcut, event| {
                // Fire on press only; the plugin reports both edges.
                if event.state() == ShortcutState::Pressed {
                    handler(app, action);
                }
            });
        match result {
            Ok(()) => log::info!("Bound {:?} to {}", action, action.label()),
            Err(e) => log::warn!("Could not bind {}: {e}", action.label()),
        }
    }
}

/// Bring the deck to the front — what the tray icon and a few hotkeys do.
pub fn show_deck<R: Runtime>(app: &AppHandle<R>) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.set_focus();
    }
}
