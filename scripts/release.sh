#!/usr/bin/env bash
# Release pipeline: build → sign → notarize → package → appcast → GitHub Release.
#
#   ./scripts/release.sh <version>        e.g. ./scripts/release.sh 0.2.0
#
# One-time setup is documented in RELEASING.md. Requires: xcodegen, gh (authed),
# a "Developer ID Application" certificate in the login keychain, and a notarytool
# keychain profile (default name "yapper-notary", override with NOTARY_PROFILE).
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: $0 <semver>   e.g. $0 0.2.0" >&2
    exit 1
fi

NOTARY_PROFILE="${NOTARY_PROFILE:-yapper-notary}"
SPARKLE_VERSION="2.9.4"
OUT="build/release"
APP="$OUT/export/Yapper.app"
DMG="$OUT/Yapper.dmg"

# --- Preflight ---------------------------------------------------------------
for tool in xcodegen gh xcrun; do
    command -v "$tool" >/dev/null || { echo "error: $tool not found" >&2; exit 1; }
done
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo "error: no 'Developer ID Application' certificate in the keychain." >&2
    echo "Create one in Xcode → Settings → Accounts → Manage Certificates." >&2
    exit 1
fi
if grep -q "<sparkle:shortVersionString>$VERSION<" site/appcast.xml; then
    echo "error: $VERSION is already in site/appcast.xml" >&2
    exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
    echo "warning: working tree is not clean — the release commit only includes" >&2
    echo "project.yml and site/appcast.xml, but review before publishing." >&2
fi

# Repo slug from origin, so this script has no hardcoded owner.
REPO=$(git remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
MIN_OS=$(sed -n 's/^ *macOS: "\(.*\)"/\1/p' project.yml | head -1)

# Sparkle CLI tools (sign_update) — downloaded once, cached outside the repo.
SPARKLE_DIR="${SPARKLE_TOOLS_DIR:-$HOME/Library/Caches/YapperRelease/Sparkle-$SPARKLE_VERSION}"
if [[ ! -x "$SPARKLE_DIR/bin/sign_update" ]]; then
    echo "==> Fetching Sparkle $SPARKLE_VERSION tools"
    mkdir -p "$SPARKLE_DIR"
    curl -fL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
        | tar -xJ -C "$SPARKLE_DIR"
fi

# --- Version bump ------------------------------------------------------------
CUR_BUILD=$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' project.yml)
BUILD=$((CUR_BUILD + 1))
echo "==> Version $VERSION (build $BUILD)"
sed -i '' "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"$VERSION\"/" project.yml
sed -i '' "s/CURRENT_PROJECT_VERSION: \"$CUR_BUILD\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml
# Keep the landing page's version pill honest too.
sed -i '' -E "s#(<b>version</b>)[0-9]+\.[0-9]+\.[0-9]+#\1$VERSION#" site/index.html
xcodegen generate

# --- Build & export ----------------------------------------------------------
echo "==> Archiving"
rm -rf "$OUT"
mkdir -p "$OUT"
xcodebuild -project Yapper.xcodeproj -scheme Yapper -configuration Release \
    -archivePath "$OUT/Yapper.xcarchive" archive -quiet

cat > "$OUT/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>destination</key><string>export</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
PLIST

echo "==> Exporting with Developer ID signing"
xcodebuild -exportArchive -archivePath "$OUT/Yapper.xcarchive" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export" -quiet

# --- Notarize the app, then the DMG ------------------------------------------
notarize() { # <file>
    local result
    echo "==> Notarizing $(basename "$1") (this can take a few minutes)"
    result=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
    echo "$result"
    if ! grep -q "status: Accepted" <<< "$result"; then
        echo "error: notarization failed — fetch details with:" >&2
        echo "  xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE" >&2
        exit 1
    fi
}

ditto -c -k --keepParent "$APP" "$OUT/Yapper.zip"
notarize "$OUT/Yapper.zip"
xcrun stapler staple "$APP"

echo "==> Building DMG"
STAGING="$OUT/dmg-staging"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Yapper" -srcfolder "$STAGING" -ov -format UDZO -quiet "$DMG"
codesign --force --sign "Developer ID Application" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

# --- Sparkle signature + appcast entry ---------------------------------------
echo "==> Signing update for Sparkle"
SIGN_OUT=$("$SPARKLE_DIR/bin/sign_update" "$DMG")
ED_SIG=$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<< "$SIGN_OUT")
ED_LEN=$(sed -n 's/.*length="\([^"]*\)".*/\1/p' <<< "$SIGN_OUT")
[[ -n "$ED_SIG" && -n "$ED_LEN" ]] || { echo "error: could not parse sign_update output: $SIGN_OUT" >&2; exit 1; }

APPCAST_VERSION="$VERSION" APPCAST_BUILD="$BUILD" APPCAST_MIN_OS="$MIN_OS" \
APPCAST_SIG="$ED_SIG" APPCAST_LEN="$ED_LEN" APPCAST_REPO="$REPO" \
APPCAST_DATE="$(LC_ALL=en_US.UTF-8 date +"%a, %d %b %Y %H:%M:%S %z")" \
python3 - <<'PY'
import os, pathlib
e = os.environ
item = f"""
        <item>
            <title>Version {e['APPCAST_VERSION']}</title>
            <link>https://github.com/{e['APPCAST_REPO']}/releases/tag/v{e['APPCAST_VERSION']}</link>
            <pubDate>{e['APPCAST_DATE']}</pubDate>
            <sparkle:version>{e['APPCAST_BUILD']}</sparkle:version>
            <sparkle:shortVersionString>{e['APPCAST_VERSION']}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>{e['APPCAST_MIN_OS']}</sparkle:minimumSystemVersion>
            <enclosure
                url="https://github.com/{e['APPCAST_REPO']}/releases/download/v{e['APPCAST_VERSION']}/Yapper.dmg"
                type="application/octet-stream"
                sparkle:edSignature="{e['APPCAST_SIG']}"
                length="{e['APPCAST_LEN']}"/>
        </item>"""
p = pathlib.Path("site/appcast.xml")
xml = p.read_text()
marker = "<language>en</language>"
assert marker in xml, "appcast is missing its <language> marker line"
p.write_text(xml.replace(marker, marker + item, 1))
PY
echo "==> Appcast entry added to site/appcast.xml"

# --- Publish -----------------------------------------------------------------
echo
echo "Ready to publish Yapper $VERSION:"
echo "  - $DMG (notarized + stapled)"
echo "  - version bump in project.yml, new entry in site/appcast.xml"
echo
read -r -p "Commit, push, and create the GitHub release now? [y/N] " reply
if [[ "$reply" =~ ^[Yy]$ ]]; then
    git add project.yml site/appcast.xml site/index.html
    git commit -m "Release v$VERSION"
    git push origin main
    gh release create "v$VERSION" "$DMG" --title "Yapper $VERSION" --generate-notes
    echo "==> Published. Updates go live as soon as the appcast is on main (done)."
else
    echo "Not published. When ready, run:"
    echo "  git add project.yml site/appcast.xml site/index.html && git commit -m 'Release v$VERSION' && git push"
    echo "  gh release create v$VERSION $DMG --title 'Yapper $VERSION' --generate-notes"
fi
