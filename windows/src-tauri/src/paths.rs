//! Where Yapper keeps things.
//!
//! The Mac app uses `~/Library/Application Support/Yapper/`; the direct
//! counterpart is `%APPDATA%\Yapper\`. Same two children either way — the
//! settings/history store at the top and `audio-cache/` beneath it — so the
//! layout reads the same in both docs and both bug reports.
//!
//! **Why the dev subfolder.** Pipeline and UI work on this app happens on a Mac
//! (see the README), and there `dirs::data_dir()` resolves to the *very*
//! directory the Swift app owns. Sharing it is not a cosmetic clash: a dev run
//! that reads anything calls `HistoryStore::prune`, which deletes expired
//! entries **and their audio** — so a debug build could quietly eat the real
//! app's history. Off Windows, everything is namespaced under `side-b-dev/`.

use std::path::PathBuf;

/// Namespace used off-Windows so development runs can never touch the Swift
/// app's store. Windows has no such neighbour, so the path stays clean there.
#[cfg(not(windows))]
const DEV_NAMESPACE: &str = "side-b-dev";

pub fn app_dir() -> PathBuf {
    let base = dirs::data_dir().unwrap_or_else(std::env::temp_dir);
    let dir = base.join("Yapper");
    #[cfg(not(windows))]
    let dir = dir.join(DEV_NAMESPACE);
    let _ = std::fs::create_dir_all(&dir);
    dir
}

/// Where synthesized clips live. Port of `TTSCoordinator.cacheDir()`.
pub fn cache_dir() -> PathBuf {
    let dir = app_dir().join("audio-cache");
    let _ = std::fs::create_dir_all(&dir);
    dir
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Guards the one mistake here that destroys user data rather than just
    /// confusing someone: a Mac dev build sharing the Swift app's store.
    #[test]
    #[cfg(not(windows))]
    fn development_runs_never_share_the_mac_apps_directory() {
        let mac_app_dir = dirs::data_dir().unwrap().join("Yapper");
        let ours = app_dir();
        assert_ne!(
            ours, mac_app_dir,
            "the dev build must not share the Mac app's store"
        );
        assert!(ours.starts_with(&mac_app_dir));
        assert!(ours.ends_with(DEV_NAMESPACE));
    }

    #[test]
    fn the_cache_sits_under_the_app_directory() {
        assert_eq!(cache_dir().parent().unwrap(), app_dir());
    }
}
