#!/usr/bin/env python3
"""Rebuild site/index.html from site/src/.

Edit template.html (copy, styles, script), then:  python3 site/src/build.py
Assets (deck/reel/cap WebPs, Permanent Marker TTF) are inlined as data URIs so the
output is a self-contained file — host it anywhere, no build pipeline. Exception:
the demo-deck voice clips ship as sibling files in site/audio/ (river-1..9.mp3,
River preset via ElevenLabs) and are fetched lazily on Play, not inlined — deploy
that folder alongside index.html. Regenerate them with site/src/gen_river.py when
the template's LINES text changes (no rebuild needed — they aren't inlined here).
Likewise site/media/ (the demo clip + its poster), favicon.svg, apple-touch-icon.png
and og.png are sibling files: deploy the whole site/ folder, not just index.html.
The nav mark is favicon.svg inlined, so the tab icon and the page logo can't drift.

Deck geometry (reel centers, cap sprite rects, hotspots, speed marking) lives in
template.html's CSS, transcribed from Yapper/UI/CassettePlayerView.swift — the app
is the source of truth; re-measure there if the art changes. The cap WebPs are
lossless re-encodes of Yapper/Resources/cassette-cap-*.png (cwebp -lossless -exact),
so they stay pixel-registered over the baked deck art.
"""
import base64, pathlib

SRC = pathlib.Path(__file__).resolve().parent
OUT = SRC.parent / "index.html"

def b64(name): return base64.b64encode((SRC / name).read_bytes()).decode()
def webp(name): return "data:image/webp;base64," + b64(name)

tpl = (SRC / "template.html").read_text()
tpl = tpl.replace("__FONT__", b64("PermanentMarker.ttf"))
tpl = tpl.replace("__DECK__", webp("deck.webp"))
tpl = tpl.replace("__REELL__", webp("reel-left.webp"))
tpl = tpl.replace("__REELR__", webp("reel-right.webp"))
for cap in ("rew", "play", "stop", "ff", "rec"):
    tpl = tpl.replace(f"__CAP{cap.upper()}__", webp(f"cap-{cap}.webp"))
tpl = tpl.replace("__TAPE__", webp("cta-tape.webp"))
tpl = tpl.replace("__MINIMAL__", webp("shell-minimal.webp"))   # the real MiniPlayerView, rendered offscreen at 3x
tpl = tpl.replace("__MARK__", "data:image/svg+xml;base64," +
                  base64.b64encode((SRC.parent / "favicon.svg").read_bytes()).decode())

head_end = tpl.index("</style>") + len("</style>")
head, body = tpl[:head_end], tpl[head_end:]
full = ("<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
        "<link rel=\"icon\" href=\"favicon.svg\" type=\"image/svg+xml\">\n"
        "<link rel=\"apple-touch-icon\" href=\"apple-touch-icon.png\">\n"
        + head + "\n</head>\n<body>" + body + "\n</body>\n</html>\n")
OUT.write_text(full)
print(f"built {OUT} ({len(full)/1024:.0f} KB)")
