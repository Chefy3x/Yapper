#!/usr/bin/env python3
"""Rebuild site/styleguide.html from site/src/styleguide-template.html.

Edit the template, then:  python3 site/src/build_styleguide.py
Only the Permanent Marker font is inlined — the guide uses no images.
"""
import base64, pathlib

SRC = pathlib.Path(__file__).resolve().parent
OUT = SRC.parent / "styleguide.html"

font = base64.b64encode((SRC / "PermanentMarker.ttf").read_bytes()).decode()
tpl = (SRC / "styleguide-template.html").read_text().replace("__FONT__", font)

head_end = tpl.index("</style>") + len("</style>")
head, body = tpl[:head_end], tpl[head_end:]
full = ("<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
        "<link rel=\"icon\" href=\"data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>🏷️</text></svg>\">\n"
        + head + "\n</head>\n<body>" + body + "\n</body>\n</html>\n")
OUT.write_text(full)
print(f"built {OUT} ({len(full)/1024:.0f} KB)")
