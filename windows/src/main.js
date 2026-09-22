// Yapper — Side B deck.
//
// The backend owns every decision that matters: segmentation, the playhead,
// which transcript line is live, what History says. This file draws that and
// sends intent back. Anything computed here that the Rust side already computes
// would be a second source of truth and a parity bug waiting to happen.

const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => Array.from(document.querySelectorAll(sel));

// ── State ────────────────────────────────────────────────────────────────

let snapshot = null;
let settings = null;
let catalog = null;
/** True while the pointer is down on the groove, so incoming snapshots don't
 *  yank the needle out from under the drag. */
let scrubbing = false;

const STATES = {
  idle: "IDLE",
  bufferingFirstAudio: "BUFFERING",
  playing: "PLAYING",
  paused: "PAUSED",
  finished: "DONE",
  failed: "FAILED",
};

// ── Deck rendering ───────────────────────────────────────────────────────

const clock = (s) => {
  if (!Number.isFinite(s) || s < 0) s = 0;
  const m = Math.floor(s / 60);
  const sec = Math.floor(s % 60);
  return `${String(m).padStart(2, "0")}:${String(sec).padStart(2, "0")}`;
};

function renderDeck() {
  const state = snapshot?.state ?? "idle";
  const total = snapshot?.totalDuration ?? 0;
  const now = snapshot?.currentTime ?? 0;

  const chip = $("#chip-state");
  chip.textContent = STATES[state] ?? state.toUpperCase();
  chip.classList.toggle("is-live", state === "playing" || state === "bufferingFirstAudio");
  chip.classList.toggle("is-bad", state === "failed");

  $("#chip-rate").textContent = `${snapshot?.rate ?? 1}×`;
  $("#counter").textContent = `${clock(now)} / ${clock(total)}`;

  // Cap sprites are the pressed visual for whatever the transport is doing.
  const down = { play: state === "playing", stop: state === "idle" || state === "finished" };
  $$(".cap").forEach((cap) => {
    cap.classList.toggle("is-down", Boolean(down[cap.dataset.cap]));
  });

  if (!scrubbing) {
    const pct = total > 0 ? Math.min(100, (now / total) * 100) : 0;
    $("#needle").style.left = `${pct}%`;
  }

  // Buffered stretches, on the same scale as the needle.
  const marks = $("#ruler-buffered");
  marks.replaceChildren();
  if (total > 0) {
    for (const [from, to] of snapshot?.bufferedRanges ?? []) {
      const el = document.createElement("span");
      el.style.left = `${(from / total) * 100}%`;
      el.style.width = `${Math.max(0, ((to - from) / total) * 100)}%`;
      marks.append(el);
    }
  }
}

function renderTranscript() {
  const list = $("#transcript");
  const lines = snapshot?.transcript ?? [];
  if (lines.length === 0) {
    list.replaceChildren(Object.assign(document.createElement("li"), { className: "empty", textContent: "—" }));
    return;
  }
  list.replaceChildren(
    ...lines.map((line, i) => {
      const li = document.createElement("li");
      li.className = [
        i === snapshot.activeLine ? "is-active" : "",
        line.isFailed ? "is-failed" : "",
        !line.isLoaded && !line.isFailed ? "is-pending" : "",
      ].filter(Boolean).join(" ");
      li.title = line.isFailed
        ? "This line failed to synthesize and won't be spoken."
        : line.isLoaded
          ? "Click to jump here."
          : "Not synthesized yet — clicking parks the deck here until it lands.";

      const idx = document.createElement("span");
      idx.className = "idx";
      idx.textContent = String(i + 1).padStart(2, "0");

      const body = document.createElement("span");
      body.textContent = line.text;

      li.append(idx, body);
      li.addEventListener("click", () => invoke("seek", { seconds: line.start }));
      return li;
    }),
  );
}

// Reels spin in lockstep, integrated per frame so the motion survives pauses and
// speed changes without jumping. Buffering creeps rather than freezing — the
// deck is working, and a dead-still reel reads as a hang.
let reelAngle = 0;
let lastFrame = performance.now();

function spin(now) {
  const dt = Math.min(0.1, (now - lastFrame) / 1000);
  lastFrame = now;
  const state = snapshot?.state;
  const rate = snapshot?.rate ?? 1;
  const degPerSec = state === "playing" ? 90 * rate : state === "bufferingFirstAudio" ? 12 : 0;
  if (degPerSec > 0) {
    reelAngle = (reelAngle + degPerSec * dt) % 360;
    document.documentElement.style.setProperty("--angle", `${reelAngle}deg`);
  }
  requestAnimationFrame(spin);
}

// ── Transport intent ─────────────────────────────────────────────────────

async function readPastedText() {
  const text = $("#read-in").value;
  const err = $("#read-err");
  err.hidden = true;
  if (!text.trim()) {
    err.textContent = "Paste something first.";
    err.hidden = false;
    return;
  }
  try {
    await invoke("speak", { text });
    refreshHistory();
  } catch (e) {
    err.textContent = String(e);
    err.hidden = false;
  }
}

function wireTransport() {
  const actions = {
    play: () => invoke("pause_or_resume"),
    stop: () => invoke("stop"),
    rew: () => invoke("step_rate", { up: false }),
    ff: () => invoke("step_rate", { up: true }),
    rec: readPastedText,
  };
  $$(".hot").forEach((btn) => {
    btn.addEventListener("click", () => actions[btn.dataset.act]?.());
  });

  $("#read-in").addEventListener("keydown", (e) => {
    if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) readPastedText();
  });

  // Scrub on the groove. Absolute mapping: the pointer's position along the
  // rail IS the target time, same as the Mac deck.
  const ruler = $("#ruler");
  const timeAt = (e) => {
    const box = ruler.getBoundingClientRect();
    const frac = Math.min(1, Math.max(0, (e.clientX - box.left) / box.width));
    return frac * (snapshot?.totalDuration ?? 0);
  };
  ruler.addEventListener("pointerdown", (e) => {
    if (!snapshot) return;
    scrubbing = true;
    ruler.setPointerCapture(e.pointerId);
    $("#needle").style.left = `${((timeAt(e) / snapshot.totalDuration) * 100) || 0}%`;
  });
  ruler.addEventListener("pointermove", (e) => {
    if (!scrubbing || !snapshot) return;
    $("#needle").style.left = `${((timeAt(e) / snapshot.totalDuration) * 100) || 0}%`;
  });
  ruler.addEventListener("pointerup", (e) => {
    if (!scrubbing) return;
    scrubbing = false;
    ruler.releasePointerCapture(e.pointerId);
    invoke("seek", { seconds: timeAt(e) });
  });
}

// ── Settings ─────────────────────────────────────────────────────────────

function option(value, label) {
  const o = document.createElement("option");
  o.value = value;
  o.textContent = label;
  return o;
}

function fillModelSelect(select, blurbEl, models, current) {
  select.replaceChildren(...models.map((m) => option(m.id, m.displayName)));
  select.value = current;
  const showBlurb = () => {
    blurbEl.textContent = models.find((m) => m.id === select.value)?.blurb ?? "";
  };
  showBlurb();
  select.addEventListener("change", showBlurb);
}

async function loadSettings() {
  [settings, catalog] = await Promise.all([invoke("get_settings"), invoke("list_voices")]);

  // The system voices are whatever Windows has installed, so they're listed
  // separately from the fixed cross-platform catalog.
  const voice = $("#voice");
  voice.replaceChildren();
  const group = (label, items) => {
    if (items.length === 0) return;
    const g = document.createElement("optgroup");
    g.label = label;
    g.append(...items);
    voice.append(g);
  };
  const byProvider = (p) => catalog.presets.filter((v) => v.provider === p).map((v) => option(v.id, v.displayName));
  group("ElevenLabs", byProvider("elevenLabs"));
  group("OpenAI", byProvider("openAI"));
  group("Windows", [
    ...byProvider("macOSNative"),
    ...catalog.system.map((v) => option(v.id, v.displayName)),
  ]);
  group("Your voices", catalog.custom.map((v) => option(v.id, v.displayName)));
  voice.value = settings.activeVoiceId;

  fillModelSelect($("#model-elevenlabs"), $("#model-elevenlabs-blurb"), catalog.elevenLabsModels, settings.elevenLabsModelId);
  fillModelSelect($("#model-openai"), $("#model-openai-blurb"), catalog.openAiModels, settings.openAiModelId);

  $("#retention").value = settings.historyRetentionHours;
  $("#native-offline").checked = settings.useNativeVoiceOffline;
  $("#launch-at-login").checked = settings.launchAtLogin;

  for (const provider of ["elevenLabs", "openAI"]) {
    const chip = document.querySelector(`[data-key-state="${provider}"]`);
    chip.textContent = (await invoke("has_api_key", { provider })) ? "STORED" : "NOT SET";
    chip.classList.toggle("is-live", chip.textContent === "STORED");
  }
}

async function saveSettings(patch) {
  settings = await invoke("save_settings", { next: { ...settings, ...patch } });
}

function wireSettings() {
  $("#voice").addEventListener("change", (e) => saveSettings({ activeVoiceId: e.target.value }));
  $("#voice-preview").addEventListener("click", () =>
    invoke("preview_voice", { voiceId: $("#voice").value }).catch(() => {}),
  );
  $("#model-elevenlabs").addEventListener("change", (e) => saveSettings({ elevenLabsModelId: e.target.value }));
  $("#model-openai").addEventListener("change", (e) => saveSettings({ openAiModelId: e.target.value }));
  $("#retention").addEventListener("change", (e) =>
    saveSettings({ historyRetentionHours: Number(e.target.value) || 24 }),
  );
  $("#native-offline").addEventListener("change", (e) => saveSettings({ useNativeVoiceOffline: e.target.checked }));
  $("#launch-at-login").addEventListener("change", (e) => saveSettings({ launchAtLogin: e.target.checked }));

  $$("[data-save-key]").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const provider = btn.dataset.saveKey;
      const input = provider === "elevenLabs" ? $("#key-elevenlabs") : $("#key-openai");
      try {
        await invoke("set_api_key", { provider, key: input.value });
        input.value = "";
        loadSettings();
      } catch (e) {
        alert(String(e));
      }
    });
  });

  // Rendered from the backend's own table so the list can't drift from the
  // chords actually registered.
  $("#keys").replaceChildren(
    ...[
      ["Ctrl + Alt + Y", "Read latest / play-pause"],
      ["Ctrl + Alt + S", "Read selection"],
      ["Ctrl + Alt + Enter", "Toggle Conversation Mode"],
      ["Ctrl + Alt + →", "Skip to next queued read"],
    ].map(([combo, what]) => {
      const li = document.createElement("li");
      const c = document.createElement("span");
      c.className = "combo";
      c.textContent = combo;
      const w = document.createElement("span");
      w.textContent = what;
      li.append(c, w);
      return li;
    }),
  );
}

// ── History ──────────────────────────────────────────────────────────────

async function refreshHistory() {
  const rows = await invoke("list_history");
  const list = $("#history");
  if (rows.length === 0) {
    list.replaceChildren(Object.assign(document.createElement("li"), { className: "empty", textContent: "Nothing read yet." }));
    return;
  }
  list.replaceChildren(
    ...rows.map((row) => {
      const li = document.createElement("li");

      const meta = document.createElement("span");
      meta.className = "meta";
      meta.textContent = new Date(row.createdAt).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });

      const text = document.createElement("span");
      text.className = "text";
      text.textContent = row.preview;
      // The clip may have been pruned; replay re-synthesizes when it has.
      text.title = `${row.originLabel} · ${row.hasAudio ? "cached" : "will re-synthesize"}`;

      const play = document.createElement("button");
      play.textContent = "REPLAY";
      play.addEventListener("click", () => invoke("replay", { id: row.id }));

      const del = document.createElement("button");
      del.className = "danger ghost";
      del.textContent = "×";
      del.title = "Delete this read and its audio";
      del.addEventListener("click", async () => {
        await invoke("delete_history_entry", { id: row.id });
        refreshHistory();
      });

      li.append(meta, text, play, del);
      return li;
    }),
  );
}

// ── Parity tools ─────────────────────────────────────────────────────────

async function runParity() {
  // Same order a real read takes: clean the markdown, then segment what's left.
  const cleaned = await invoke("clean_text", { text: $("#parity-in").value });
  const segments = await invoke("segment_text", { text: cleaned });

  $("#parity-cleaned").textContent = cleaned || "—";
  const list = $("#parity-segments");
  if (segments.length === 0) {
    list.replaceChildren(Object.assign(document.createElement("li"), { className: "empty", textContent: "—" }));
  } else {
    list.replaceChildren(
      ...segments.map((seg, i) => {
        const li = document.createElement("li");
        const idx = document.createElement("span");
        idx.className = "idx";
        idx.textContent = String(i + 1).padStart(2, "0");
        const body = document.createElement("span");
        body.textContent = seg;
        const chars = document.createElement("span");
        chars.className = "chars";
        chars.textContent = `${[...seg].length}c`;
        li.append(idx, body, chars);
        return li;
      }),
    );
  }
  $("#parity-stat").textContent = `${segments.length} SEGMENT${segments.length === 1 ? "" : "S"}`;
}

// ── Boot ─────────────────────────────────────────────────────────────────

function wireTabs() {
  $$(".tab").forEach((tab) => {
    tab.addEventListener("click", () => {
      $$(".tab").forEach((t) => t.classList.toggle("is-on", t === tab));
      $$(".panel").forEach((p) => p.classList.toggle("is-on", p.dataset.panel === tab.dataset.tab));
      if (tab.dataset.tab === "history") refreshHistory();
      if (tab.dataset.tab === "settings") loadSettings();
    });
  });
}

async function boot() {
  wireTabs();
  wireTransport();
  wireSettings();
  $("#parity-run").addEventListener("click", runParity);

  $("#guide-done").addEventListener("click", async () => {
    await saveSettings({ onboardingCompleted: true });
    $("#onboarding").hidden = true;
  });

  await loadSettings();
  await refreshHistory();

  if (await invoke("should_show_onboarding")) {
    $("#onboarding").hidden = false;
  }

  // The backend pushes a snapshot on its own 10 Hz clock; the UI never polls.
  await listen("player", (event) => {
    snapshot = event.payload;
    renderDeck();
    renderTranscript();
  });

  await listen("conversation-mode", (event) => {
    $("#chip-queue").hidden = !event.payload;
  });

  snapshot = await invoke("player_snapshot");
  renderDeck();
  renderTranscript();
  requestAnimationFrame(spin);
}

window.addEventListener("DOMContentLoaded", boot);
