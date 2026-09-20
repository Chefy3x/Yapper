# Yapper for Windows (Side B)

The Windows build of Yapper — a [Tauri v2](https://tauri.app) app: Rust backend,
WebView2 frontend reusing the tape-label design system from `../site/styleguide.html`.
The macOS app stays native Swift; this directory shares its *behavior* (pinned by
parity tests), not its code.

## Layout

```
src/                  frontend (vanilla HTML/CSS/JS — no bundler)
  assets/deck/        the Mac app's baked deck art, reused as-is
src-tauri/src/
  pipeline/           portable pipeline — Rust ports of Yapper/Services/*
    segmentation.rs   SentenceStreamPlayer.segments port (ICU4X, 350/1000 caps)
    text_cleaner.rs   TextCleaner port (fancy-regex, for the lookarounds)
    elevenlabs.rs     ElevenLabsClient port (same request shape + stitching)
    openai.rs         OpenAIClient port
    synthesizer.rs    the SpeechSynthesizing protocol
    timeline.rs       the *arithmetic* half of SentenceStreamPlayer
    player.rs         the *transport* half
  audio/              decode + output (the AVAudioPlayer half)
  coordinator.rs      TTSCoordinator port
  history.rs          HistoryStore port
  settings.rs         SettingsStore port (JSON file — Windows has no UserDefaults)
  credentials.rs      Keychain port (Windows Credential Manager)
  native_tts.rs       NativeTTSSpeaker port (WinRT SpeechSynthesizer)
  shortcuts.rs        HotkeyManager port
  reader/             Windows-only UIA layer (AccessibilityReader counterpart)
```

## Developing

Pipeline + UI development works on any OS (including macOS):

```sh
npm install
npm run tauri dev     # runs the app
cargo test            # in src-tauri/ — 80 parity tests, no network, no audio device
```

Everything except `reader/` and the WinRT half of `native_tts.rs` builds and runs
on a Mac. Those two are `#[cfg(windows)]`; CI on `windows-latest` is what proves
they still compile (see `.github/workflows/windows.yml`).

To type-check the Windows-only code from a Mac, extract the module and check it
against `x86_64-pc-windows-msvc` in a scratch crate that depends only on
`windows`. Checking the *whole* crate for that target fails on `ring`'s C code,
which needs MSVC headers this machine doesn't have. Worth doing, because the Send
bound on the synthesis future is easy to break and only fails on Windows.

`side-b-dev/`: off Windows the app namespaces its data directory, because
`dirs::data_dir()` on macOS resolves to the *exact* folder the Swift app owns and
`HistoryStore::prune` deletes expired entries **and their audio**. See
`src-tauri/src/paths.rs`.

## Phase plan

- [x] **1. Skeleton** — scaffold, pipeline ports (segmentation, ElevenLabs client), parity tests
- [x] **2. Playback** — stream player (playhead-priority), audio cache, WinRT speech fallback, credential storage
- [ ] **3. Reading** — UIA selection read + Ctrl+C fallback; per-app adapters (Claude desktop, ChatGPT desktop, browsers on AI sites)
- [x] **4. Shell/UI** — tray, global hotkeys, deck, transcript, settings, History, first-run guide
      *(remainder: the right-Alt tap gesture — needs a low-level keyboard hook)*
- [ ] **5. Distribution** — CI + NSIS installer done; Authenticode signing, updater feed, site download, winget outstanding

### What Phase 3 needs

`reader/mod.rs` is a documented skeleton whose two entry points return
`ReadError::NotImplemented` (they're reachable from a hotkey, so they report
rather than panic). The work needs a Windows box, because element trees have to
be inspected live:

- **Inspector** — [Accessibility Insights for Windows](https://accessibilityinsights.io),
  with `inspect.exe` from the Windows SDK as the more truthful fallback.
- **Crates** — `windows` for the UIA COM interfaces and `SendInput`,
  `arboard` for clipboard save/restore.
- **The gotcha** — Chromium (so Electron, so Claude desktop, ChatGPT desktop, and
  every browser) builds its accessibility tree *lazily*, once a UIA client asks.
  The first `GetSelection()` can come back empty because the tree isn't
  populated, not because the adapter is wrong. Test with
  `--force-renderer-accessibility` to tell the two apart.
- **Then** wire `Coordinator::enqueue` — the Conversation Mode queue is finished
  and tested, and nothing feeds it until a reader exists.
- **Voice In parity** — the Mac side now has hold-a-modifier push-to-talk (Right ⌥ by default, `YapperKey`) and a
  hands-free turn after each reply, transcribed locally with WhisperKit and
  pasted into the focused composer (never auto-sent). The Windows equivalent is
  `whisper-rs` (whisper.cpp bindings) + `cpal` for capture, with the same
  `TranscriptFilter` / `VoiceActivityDetector` / `ModifierGesture` rules
  ported as pure functions and mirrored in the parity tests.

### What Phase 5 needs

CI builds an unsigned NSIS installer and uploads it as an artifact. Outstanding:

- **A certificate, and a decision about whose name is on it.** An Authenticode
  signature embeds the subject name in the binary — visible in the file's
  properties, and echoed in the winget manifest's publisher field. Signing as an
  individual ships the signer's legal name inside every copy, and unlike the Mac
  side's Team ID it can't live in a gitignored file, because it's *in the
  artifact*. Signing through an organisation is the usual way around that.
  Routes: Azure Trusted Signing (cheap, monthly, identity validation with
  eligibility rules worth re-checking) or an OV certificate on a hardware
  token/HSM. Unsigned works but meets a SmartScreen wall.
- **The updater feed.** `tauri-plugin-updater` is the Sparkle counterpart: a
  signed JSON manifest instead of `appcast.xml`. Generate the keypair with
  `npm run tauri signer generate`, put the public half in
  `tauri.conf.json` (`plugins.updater.pubkey`, currently a placeholder) and the
  private half in repo secrets. **Back the private key up outside this repo** —
  losing it means shipped copies can never update again, same rule as the
  Sparkle EdDSA key in `../RELEASING.md`.
- **The release flow** — tag → build → sign → publish → write the feed. CI
  deliberately has no tag trigger yet; see the note in the workflow.
- **winget** — `wingetcreate` for the manifest, the `winget-releaser` action to
  submit on release. Needs a publicly downloadable, signed installer first.

## Parity rule

Any change to segmentation caps, text cleaning, or the ElevenLabs request shape
must land on **both** sides (Swift + Rust) with matching test updates. The tests
in `pipeline/`, `history.rs`, `models.rs` and `settings.rs` mirror `YapperTests/`
case-for-case, and say so where they do.

Tests that have no Swift counterpart are marked "Rust-side only". Most of the
transport is in that group: the Swift player is `@MainActor` and welded to
`AVAudioPlayer`, so its scrub/stitch/cache-completeness rules only exist as code
comments over there. Splitting the arithmetic (`timeline.rs`) from the transport
(`player.rs`) made them testable here. Treat those as the contract to hold the
Swift side to.

### Deliberate divergences

| | macOS | Windows | why |
|---|---|---|---|
| Native voice | a second engine (`Engine.native`) with no scrubber | just another `SpeechSynthesizing` | WinRT returns a complete WAV instead of driving the speakers, so it rides the same player — the deck keeps its scrubber and transcript offline |
| Segment finished | `AVAudioPlayer` delegate callback | polled on the 10 Hz tick | one clock instead of two, and it makes seams steppable in tests |
| Read gesture | right-Command *tap* (`CGEventTap`) | `Ctrl+Alt` chords | no cross-platform equivalent; the tap needs a `WH_KEYBOARD_LL` hook (Phase 4 remainder) |
| Character counts | grapheme clusters | Unicode scalars | identical for ASCII; irrelevant at cap/estimate scale |
| Sentence boundaries | Apple's `.bySentences` tokenizer | ICU4X (UAX #29) | both need sentence-like cues; the golden tests pin the cases that matter |
