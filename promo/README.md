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
