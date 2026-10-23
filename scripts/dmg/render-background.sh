#!/usr/bin/env bash
# Renders background.html to background.tiff (600×400 at 1x and 2x) for the DMG window.
# Only needed when background.html changes; the TIFF is committed. Needs Google Chrome.
set -euo pipefail

cd "$(dirname "$0")"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[[ -x "$CHROME" ]] || { echo "error: Google Chrome not found" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for scale in 1 2; do
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --no-first-run \
        --window-size=600,400 --force-device-scale-factor=$scale \
        --virtual-time-budget=4000 \
        --screenshot="$TMP/bg@${scale}x.png" "file://$PWD/background.html" >/dev/null 2>&1
done

# One TIFF holding both, so Finder picks the sharp one on Retina screens.
tiffutil -cathidpicheck "$TMP/bg@1x.png" "$TMP/bg@2x.png" -out background.tiff >/dev/null
echo "wrote $(pwd)/background.tiff"
