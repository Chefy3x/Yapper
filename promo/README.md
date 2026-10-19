# Yapper promo

A from-scratch, 9-second Remotion promo based on the Yapper product spec and
the real cassette-deck art. The edit uses rapid hard cuts, motion typography,
an animated Right Command key, flowing audio graphics, spinning reels, and a
tape-label end card.

## Storyboard

1. An oversized AI answer floods the screen.
2. Right Command interrupts it.
3. Text is routed into the cassette as audio.
4. Yapper's promise lands: “Reads your AI out loud.”
5. Claude, ChatGPT, Codex, and highlighted text flash by.
6. Yapper label and “Tap Right Command and walk away.”

## Commands

```bash
npm install
npm run dev
npm run render
```

The render is written to `out/yapper-promo.mp4` at 1920×1080, 30fps.

## Alternate: Walkaway

`YapperWalkaway` is a separate 9.5-second concept. An AI answer completes,
Right Command lights up, the response winds into the cassette, and three
rapid lifestyle cuts show the user leaving the screen while Yapper keeps
reading. The first promo and its output remain untouched.

```bash
npm run render:walkaway
```

The alternate render is written to `out/yapper-walkaway.mp4`.

## Alternate: Side A

`YapperSideA` is a 9.4-second, nine-shot mixtape edit built fresh from the
spec — all type, tape-label paper, and the real deck art. Streaming "yap"
ribbons → label cards ("Don't read it." / "Press play.") → the Right ⌘ keycap
tap → deck hero with spinning reels and VU meters → three feature stabs
(code skip, 2× FF, REC conversation mode) → a yellow label end card with
spinning hubs. Each shot carries an `NN · SIDE A` index chip; cuts are hard
with two-frame flashes and sfx hits.

```bash
npm run render:side-a
```

The render is written to `out/yapper-side-a.mp4`.

## Main: Real Flow

`YapperRealFlow` is a 29.8s recreation of the actual product flow, captured by
driving the installed app: Right ⌥ was posted as a synthetic `flagsChanged`
event to Yapper's CGEventTap while the Claude desktop app was frontmost, and
the deck that appeared (460x284, `miniPlayerTheme = cassette`) is what the
composition rebuilds.

Seven shots, opening on the object: the deck alone in the dark → the reply
nobody is going to read → the Right ⌥ keycap tap → the deck docks into the
corner → it reads the reply, with the spoken sentence highlighted in the window
and the camera pushed in on the paragraph, then the screen falls away and the
deck plays alone → three feature stabs → tape-label end card.

Everything is measured rather than eyeballed:

- **Voice** — `public/audio/read.mp3` is ElevenLabs **River**, the preset Yapper
  actually ships, at the app's tuned settings (stability 0.40, style 0.30,
  `eleven_multilingual_v2`).
- **Sentence sync** — `src/read/timing.ts` carries the four sentence windows
  taken from `ffmpeg silencedetect` on that render, so the on-screen highlight
  tracks the voice instead of guessing. `READ_B` / `READ_C` are placed on
  sentence boundaries, so the cuts never land mid-word.
- **Level meter** — `src/read/envelope.ts` is the per-frame RMS of the same
  file, measured with ffmpeg and smoothed fast-attack/slow-release. The meter
  goes still in the real pauses.
- **The chat window** — `src/read/ChatWindow.tsx` is rebuilt against a real
  capture of the app. The palette is sampled off flat regions of that capture
  with ImageMagick (`#151515` main, `#131313` rail, `#181818` composer,
  `#EBEAE7` body), and the layout holds the reference's proportions: a 16.3%
  rail and a message column centred at 64% of the main area. Body type runs at
  1.6x the app's default scale, because the true ratio is unreadable at 1080p.
  All on-screen content is invented — no real chat titles.
- **Deck geometry** — reel and cap registration come from
  `CassettePlayerView.swift`, via the existing `CassetteDeck` component. The
  deck sits outside the camera transform, so it stays anchored while the app
  zooms, exactly as a floating panel behaves.

### Audio sources

- **Music** — HeyGen catalog, resolved through the `media-use` skill
  (`resolve --type bgm`). The track's section marker at 23s is why the music
  starts at 0:00: it lands exactly on the cut into the feature stabs.
- **SFX** — cut from the user's own Epidemic Sound library: one mechanical
  click sliced out of a "Variations" take for the keycap, that same click
  pitched down and layered under a deep whoosh for the deck's transport clunk,
  plus whoosh / swoosh / riser for the transitions.
- ElevenLabs Music was the first choice but that API key is missing the
  `music_generation` permission.

Mixed with the bed ducked ~10 dB under the voice, then normalized to
**-13.4 LUFS / -0.8 dBTP** for web.

> **Licensing:** `public/audio/` and `.media/` are gitignored. The Epidemic
> Sound SFX and the HeyGen catalog track are licensed for use *in* renders, not
> for redistribution as raw files, and this repo is public. Only the rendered
> MP4 carries them; regenerate the sources locally with the commands above.

```bash
npm run render:real
```

The render is written to `out/yapper-real-flow.mp4` at 1920x1080, 30fps.
