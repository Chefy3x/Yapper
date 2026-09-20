#!/usr/bin/env python3
"""Regenerate the demo-deck voice clips (site/audio/river-1..9.mp3) via ElevenLabs.

The site's cassette deck plays these pre-rendered clips as the "real voice"; the
browser's speech engine is only the offline understudy. Run this whenever the LINES
text below changes — and keep it byte-for-byte in sync with template.html's LINES.

    ELEVEN_KEY="$(security find-generic-password -s app.yapper.Yapper \
        -a elevenlabs.api.key -w)" python3 site/src/gen_river.py
    python3 site/src/build.py   # (no rebuild needed — audio is not inlined)

Voice + settings mirror Yapper's app defaults exactly: River preset
(Models/VoicePreset.swift) and ElevenLabsClient.VoiceSettings.natural, on
eleven_multilingual_v2. The key is read from env ELEVEN_KEY and never written to disk.
"""
import json, os, sys, urllib.request, urllib.error, pathlib

KEY = os.environ.get("ELEVEN_KEY", "").strip()
if not KEY:
    sys.exit("ELEVEN_KEY not set — read it from the Keychain (see module docstring).")

VOICE_ID = "SAz9YHcvj6GT2YYXdXww"          # River
MODEL_ID = "eleven_multilingual_v2"
OUT_FMT  = "mp3_44100_128"
SETTINGS = {                                # ElevenLabsClient.VoiceSettings.natural
    "stability": 0.40,
    "similarity_boost": 0.80,
    "style": 0.30,
    "use_speaker_boost": True,
}

# MUST stay in sync with template.html LINES (same order, same text).
LINES = [
    "Hi. I'm Yapper — a tape deck that lives in your Mac's menu bar.",
    "When Claude, ChatGPT, or Codex finishes a reply, I read it out loud. You go make coffee.",
    "Tap the right Option key: the newest reply, spoken. Tap again to pause. That's the whole manual.",
    "Highlight anything, anywhere — right Option plus S — and congratulations, it's a podcast now.",
    "Press record, and every new reply auto-plays the moment it lands. They queue. They never talk over each other.",
    "Code blocks? Skipped. Markdown? Stripped. You hear prose, not punctuation.",
    "What you're hearing is my real voice — ElevenLabs, the River preset. The same one Yapper ships.",
    "If the network dies, I fall back to the Mac's built-in voice and keep rolling.",
    "That's Side A. Side B is coming. Yapper — reads aloud, stays out of your way.",
]

# Default to site/audio (sibling of this script's parent); allow an override argv[1].
AUDIO_DIR = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent.parent / "audio"
AUDIO_DIR.mkdir(parents=True, exist_ok=True)

total = 0
for i, text in enumerate(LINES):
    body = {"text": text, "model_id": MODEL_ID, "voice_settings": SETTINGS}
    if i > 0:               body["previous_text"] = LINES[i - 1]   # prosodic continuity across
    if i < len(LINES) - 1:  body["next_text"] = LINES[i + 1]       # segment seams (text-only)

    url = f"https://api.elevenlabs.io/v1/text-to-speech/{VOICE_ID}?output_format={OUT_FMT}"
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        headers={"xi-api-key": KEY, "Content-Type": "application/json", "Accept": "audio/mpeg"},
        method="POST",
    )
    dest = AUDIO_DIR / f"river-{i+1}.mp3"
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            data = r.read()
    except urllib.error.HTTPError as e:
        sys.exit(f"[{i+1}] HTTP {e.code}: {e.read().decode('utf-8', 'replace')[:500]}")
    except Exception as e:
        sys.exit(f"[{i+1}] {type(e).__name__}: {e}")
    dest.write_bytes(data)
    total += len(data)
    print(f"[{i+1}/{len(LINES)}] {len(data)/1024:6.1f} KB  {dest.name}  «{text[:42]}…»")

print(f"done — {total/1024:.0f} KB across {len(LINES)} clips in {AUDIO_DIR}")
