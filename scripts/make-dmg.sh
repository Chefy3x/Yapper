#!/usr/bin/env bash
# Packs Yapper.app into the drag-to-Applications DMG: the background from scripts/dmg,
# Yapper on the left, an Applications link on the right, the arrow between them.
#
#   ./scripts/make-dmg.sh <path/to/Yapper.app> <out.dmg>
#
# release.sh calls this; it also works on its own to preview the window from any build.
# Needs create-dmg (brew install create-dmg). Finder lays the window out over AppleScript,
# so the first run asks to let the terminal control Finder.
set -euo pipefail

APP="${1:?usage: $0 <Yapper.app> <out.dmg>}"
DMG="${2:?usage: $0 <Yapper.app> <out.dmg>}"
HERE="$(cd "$(dirname "$0")" && pwd)"

command -v create-dmg >/dev/null || { echo "error: create-dmg not found (brew install create-dmg)" >&2; exit 1; }
[[ -d "$APP" ]] || { echo "error: no app at $APP" >&2; exit 1; }

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/Yapper.app"
rm -f "$DMG"

# Icon positions are centres, in the 600×400 window the background was drawn for. The
# window is 28pt taller than the art so the title bar doesn't eat its bottom edge.
create-dmg \
    --volname "Yapper" \
    --background "$HERE/dmg/background.tiff" \
    --window-pos 200 140 \
    --window-size 600 428 \
    --icon-size 112 \
    --text-size 12 \
    --icon "Yapper.app" 150 200 \
    --hide-extension "Yapper.app" \
    --app-drop-link 450 200 \
    --no-internet-enable \
    "$DMG" "$STAGING" >/dev/null
echo "==> $DMG"
