//! Recently-spoken items, persisted for replay — port of
//! `Yapper/Services/HistoryStore.swift`.
//!
//! Audio is reused from the TTS cache for instant replay; when the cache file is
//! gone the caller re-synthesizes from `cleaned_text`. Retention is the product
//! promise ("your drive doesn't fill up, your reads don't leak past the
//! window"), so pruning and orphan sweeping get exact coverage below.
//!
//! `history.json` is written in the Swift store's exact shape — same key names,
//! same second-precision ISO-8601 timestamps — so the file is legible to either
//! app. That matters for anyone who runs Yapper on a Mac and a PC and syncs the
//! folder, and it costs nothing to hold.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::models::{preview, ReadingItem};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Origin {
    Latest,
    Selection,
    Conversation,
}

impl Origin {
    /// The words the Mac app's History rows use.
    pub fn label(self) -> &'static str {
        match self {
            Origin::Latest => "Read latest",
            Origin::Selection => "Selection",
            Origin::Conversation => "Conversation",
        }
    }
}

/// Second-precision ISO-8601, the shape Foundation's `.iso8601` strategy both
/// writes and accepts. chrono's default RFC-3339 output carries fractional
/// seconds, which that decoder rejects outright — so a Mac app reading a file
/// this one wrote would silently fall back to an empty history.
mod iso8601 {
    use chrono::{DateTime, SecondsFormat, Utc};
    use serde::{self, Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(dt: &DateTime<Utc>, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&dt.to_rfc3339_opts(SecondsFormat::Secs, true))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<DateTime<Utc>, D::Error> {
        let raw = String::deserialize(d)?;
        // Lenient on the way in: fractional seconds from any other writer parse
        // fine, they just aren't produced here.
        DateTime::parse_from_rfc3339(&raw)
            .map(|dt| dt.with_timezone(&Utc))
            .map_err(serde::de::Error::custom)
    }
}

/// One spoken item, persisted for replay within the rolling retention window.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryEntry {
    pub id: String,
    pub source_app: String,
    #[serde(with = "iso8601")]
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub cleaned_text: String,
    pub raw_text: String,
    // Swift's synthesized CodingKeys use the property name verbatim, and the
    // property is `voiceID` — which is not what camelCase would produce.
    #[serde(rename = "voiceID")]
    pub voice_id: String,
    /// Filename (within the audio cache dir) of the synthesized MP3, if any.
    /// `None` for native reads, which produce no file.
    pub audio_file_name: Option<String>,
    pub origin: Origin,
}

impl HistoryEntry {
    pub fn preview(&self) -> String {
        preview(&self.cleaned_text, 90)
    }
}

pub struct HistoryStore {
    file_path: PathBuf,
    audio_dir: PathBuf,
    entries: Vec<HistoryEntry>,
}

impl HistoryStore {
    pub fn new(storage_dir: &Path, audio_dir: &Path) -> Self {
        let _ = std::fs::create_dir_all(storage_dir);
        let _ = std::fs::create_dir_all(audio_dir);
        let mut store = Self {
            file_path: storage_dir.join("history.json"),
            audio_dir: audio_dir.to_path_buf(),
            entries: Vec::new(),
        };
        store.load();
        store
    }

    pub fn entries(&self) -> &[HistoryEntry] {
        &self.entries
    }

    // MARK: - Recording

    pub fn record(
        &mut self,
        item: &ReadingItem,
        voice_id: &str,
        audio_file_name: Option<String>,
        origin: Origin,
    ) {
        let entry = HistoryEntry {
            id: item.id.clone(),
            source_app: item.source_app.clone(),
            created_at: item.created_at,
            cleaned_text: item.cleaned_text.clone(),
            raw_text: item.raw_text.clone(),
            voice_id: voice_id.to_string(),
            audio_file_name,
            origin,
        };
        self.entries.retain(|e| e.id != entry.id);
        self.entries.insert(0, entry);
        self.save();
    }

    // MARK: - Mutations

    pub fn remove(&mut self, id: &str) {
        if let Some(pos) = self.entries.iter().position(|e| e.id == id) {
            let entry = self.entries.remove(pos);
            self.delete_audio(&entry);
        }
        self.save();
    }

    pub fn clear_all(&mut self) {
        for entry in std::mem::take(&mut self.entries) {
            self.delete_audio(&entry);
        }
        self.save();
    }

    /// Drop entries older than the retention window (deleting their audio), then
    /// sweep orphaned cache files older than the window (old previews,
    /// pre-history leftovers).
    pub fn prune(&mut self, retention_hours: i64) {
        let cutoff = chrono::Utc::now() - chrono::Duration::hours(retention_hours);
        let (expired, keep): (Vec<_>, Vec<_>) = std::mem::take(&mut self.entries)
            .into_iter()
            .partition(|e| e.created_at < cutoff);
        for entry in &expired {
            self.delete_audio(entry);
        }
        self.entries = keep;
        self.save();
        self.sweep_orphans(cutoff);
    }

    // MARK: - Audio resolution

    /// The on-disk audio file for an entry, if it still exists and is non-empty.
    /// An empty file is a truncated or failed synthesis, not a playable clip.
    pub fn audio_path(&self, entry: &HistoryEntry) -> Option<PathBuf> {
        let name = entry.audio_file_name.as_ref()?;
        let path = self.audio_dir.join(name);
        let meta = std::fs::metadata(&path).ok()?;
        (meta.is_file() && meta.len() > 0).then_some(path)
    }

    // MARK: - Persistence

    fn delete_audio(&self, entry: &HistoryEntry) {
        if let Some(name) = &entry.audio_file_name {
            let _ = std::fs::remove_file(self.audio_dir.join(name));
        }
    }

    fn load(&mut self) {
        let Ok(data) = std::fs::read(&self.file_path) else {
            self.entries = Vec::new();
            return;
        };
        let mut decoded: Vec<HistoryEntry> = serde_json::from_slice(&data).unwrap_or_default();
        decoded.sort_by_key(|e| std::cmp::Reverse(e.created_at));
        self.entries = decoded;
    }

    fn save(&self) {
        let Ok(data) = serde_json::to_vec(&self.entries) else {
            return;
        };
        // Write-then-rename: a crash mid-save must not leave a truncated store.
        let tmp = self.file_path.with_extension("json.tmp");
        if std::fs::write(&tmp, &data).is_ok() {
            let _ = std::fs::rename(&tmp, &self.file_path);
        }
    }

    fn sweep_orphans(&self, cutoff: chrono::DateTime<chrono::Utc>) {
        let referenced: Vec<&String> = self
            .entries
            .iter()
            .filter_map(|e| e.audio_file_name.as_ref())
            .collect();
        let Ok(files) = std::fs::read_dir(&self.audio_dir) else {
            return;
        };
        for file in files.flatten() {
            let path = file.path();
            // .part files are in-progress synthesis temps; old ones are
            // leftovers from a killed app.
            let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("");
            if ext != "mp3" && ext != "part" {
                continue;
            }
            let name = path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("")
                .to_string();
            if referenced.iter().any(|r| **r == name) {
                continue;
            }
            let modified = file
                .metadata()
                .and_then(|m| m.modified())
                .map(chrono::DateTime::<chrono::Utc>::from)
                .unwrap_or(chrono::DateTime::<chrono::Utc>::MIN_UTC);
            if modified < cutoff {
                let _ = std::fs::remove_file(&path);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, SystemTime};

    // Mirrors `YapperTests/HistoryStoreTests.swift` case-for-case. All stores
    // point at temp dirs — real user data is never touched.

    struct Dirs {
        audio: PathBuf,
        storage: PathBuf,
        _root: tempfile::TempDir,
    }

    fn make_dirs() -> Dirs {
        let root = tempfile::tempdir().unwrap();
        let audio = root.path().join("audio");
        let storage = root.path().join("store");
        std::fs::create_dir_all(&audio).unwrap();
        std::fs::create_dir_all(&storage).unwrap();
        Dirs {
            audio,
            storage,
            _root: root,
        }
    }

    fn item(text: &str, age_hours: i64) -> ReadingItem {
        let mut it = ReadingItem::make("TestApp", text, text);
        it.created_at = chrono::Utc::now() - chrono::Duration::hours(age_hours);
        it
    }

    fn write_audio(name: &str, dir: &Path, age_hours: u64) -> PathBuf {
        let path = dir.join(name);
        std::fs::write(&path, b"mp3-bytes").unwrap();
        if age_hours > 0 {
            let when = SystemTime::now() - Duration::from_secs(age_hours * 3600);
            filetime::set_file_mtime(&path, filetime::FileTime::from_system_time(when)).unwrap();
        }
        path
    }

    // MARK: - Recording

    #[test]
    fn records_newest_first() {
        let d = make_dirs();
        let mut store = HistoryStore::new(&d.storage, &d.audio);
        store.record(&item("first", 0), "v", None, Origin::Latest);
        store.record(&item("second", 0), "v", None, Origin::Selection);
        assert_eq!(
            store
                .entries()
                .iter()
                .map(|e| e.cleaned_text.as_str())
                .collect::<Vec<_>>(),
            ["second", "first"]
        );
    }

    #[test]
    fn persists_across_instances() {
        let d = make_dirs();
        HistoryStore::new(&d.storage, &d.audio).record(
            &item("survives reload", 0),
            "v",
            None,
            Origin::Conversation,
        );
        let reloaded = HistoryStore::new(&d.storage, &d.audio);
        assert_eq!(reloaded.entries().len(), 1);
        assert_eq!(reloaded.entries()[0].cleaned_text, "survives reload");
        assert_eq!(reloaded.entries()[0].origin, Origin::Conversation);
    }

    // MARK: - Pruning

    #[test]
    fn prune_drops_expired_entries_and_their_audio() {
        let d = make_dirs();
        let mut store = HistoryStore::new(&d.storage, &d.audio);
        let old_audio = write_audio("old.mp3", &d.audio, 2);
        let fresh_audio = write_audio("fresh.mp3", &d.audio, 0);

        store.record(
            &item("old read", 2),
            "v",
            Some("old.mp3".into()),
            Origin::Latest,
        );
        store.record(
            &item("fresh read", 0),
            "v",
            Some("fresh.mp3".into()),
            Origin::Latest,
        );

        store.prune(1);

        assert_eq!(
            store
                .entries()
                .iter()
                .map(|e| e.cleaned_text.as_str())
                .collect::<Vec<_>>(),
            ["fresh read"]
        );
        assert!(!old_audio.exists());
        assert!(fresh_audio.exists());
    }

    #[test]
    fn prune_sweeps_orphaned_audio_and_part_files() {
        let d = make_dirs();
        let mut store = HistoryStore::new(&d.storage, &d.audio);
        let old_orphan = write_audio("orphan.mp3", &d.audio, 2);
        let old_part = write_audio("stale.mp3.part", &d.audio, 2);
        let young_orphan = write_audio("young.mp3", &d.audio, 0);

        store.prune(1);

        assert!(!old_orphan.exists());
        assert!(!old_part.exists());
        // Young files survive even when unreferenced — they may belong to an
        // in-flight read.
        assert!(young_orphan.exists());
    }

    // MARK: - Audio resolution

    #[test]
    fn audio_path_requires_an_existing_non_empty_file() {
        let d = make_dirs();
        let store = HistoryStore::new(&d.storage, &d.audio);
        std::fs::write(d.audio.join("empty.mp3"), b"").unwrap();
        write_audio("real.mp3", &d.audio, 0);

        let entry = |file: Option<&str>| HistoryEntry {
            id: uuid::Uuid::new_v4().to_string(),
            source_app: "T".into(),
            created_at: chrono::Utc::now(),
            cleaned_text: "t".into(),
            raw_text: "t".into(),
            voice_id: "v".into(),
            audio_file_name: file.map(String::from),
            origin: Origin::Latest,
        };
        assert!(store.audio_path(&entry(None)).is_none());
        assert!(store.audio_path(&entry(Some("missing.mp3"))).is_none());
        // Truncated/failed synth.
        assert!(store.audio_path(&entry(Some("empty.mp3"))).is_none());
        assert!(store.audio_path(&entry(Some("real.mp3"))).is_some());
    }

    #[test]
    fn clear_all_removes_entries_and_audio() {
        let d = make_dirs();
        let mut store = HistoryStore::new(&d.storage, &d.audio);
        let file = write_audio("clip.mp3", &d.audio, 0);
        store.record(
            &item("read", 0),
            "v",
            Some("clip.mp3".into()),
            Origin::Latest,
        );

        store.clear_all();

        assert!(store.entries().is_empty());
        assert!(!file.exists());
    }

    // MARK: - Cross-platform file shape (Rust-side only)

    /// `history.json` has to stay legible to the Swift store: same key names,
    /// and timestamps Foundation's `.iso8601` decoder accepts — which means no
    /// fractional seconds.
    #[test]
    fn the_store_file_matches_the_swift_encoding() {
        let d = make_dirs();
        let mut store = HistoryStore::new(&d.storage, &d.audio);
        store.record(
            &item("hello", 0),
            "rachel",
            Some("clip.mp3".into()),
            Origin::Latest,
        );

        let raw = std::fs::read_to_string(d.storage.join("history.json")).unwrap();
        let json: serde_json::Value = serde_json::from_str(&raw).unwrap();
        let entry = &json[0];

        for key in [
            "id",
            "sourceApp",
            "createdAt",
            "cleanedText",
            "rawText",
            "voiceID",
            "audioFileName",
            "origin",
        ] {
            assert!(entry.get(key).is_some(), "missing key {key} in {entry}");
        }
        assert_eq!(entry["origin"], "latest");
        let created = entry["createdAt"].as_str().unwrap();
        assert!(created.ends_with('Z'), "got {created}");
        assert!(
            !created.contains('.'),
            "fractional seconds break Swift's decoder: {created}"
        );
    }
}
