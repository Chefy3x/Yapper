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

# Built under the system temp folder, never next to $DMG: create-dmg makes its writable
# image beside the output, and Finder's .DS_Store records that image's path, so a build in
# the home folder would ship the username inside every DMG.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/staging"
ditto "$APP" "$WORK/staging/Yapper.app"
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
    "$WORK/Yapper.dmg" "$WORK/staging" >/dev/null

# The image is compressed, so check the layout file itself on a read-only mount.
mkdir "$WORK/mnt"
hdiutil attach -nobrowse -readonly -quiet -mountpoint "$WORK/mnt" "$WORK/Yapper.dmg"
leak=$(LC_ALL=C grep -c -a -e "$HOME" -e ":Users:$USER:" "$WORK/mnt/.DS_Store" || true)
hdiutil detach -quiet "$WORK/mnt"
if [[ "$leak" != 0 ]]; then
    echo "error: the DMG's .DS_Store still carries $HOME" >&2
    exit 1
fi
mv "$WORK/Yapper.dmg" "$DMG"
echo "==> $DMG"
