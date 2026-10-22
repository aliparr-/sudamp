#!/bin/bash
# Assembles build/sudamp.app from SwiftPM products on a Command Line Tools-only machine (DESIGN §9 `make app`),
# then ad-hoc signs it inside-out. HARDENED=1 adds the hardened runtime (`make app-hardened`).
# Usage: scripts/bundle.sh [debug|release]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIG="${1:-debug}"
HARDENED="${HARDENED:-0}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 0)}"
BUNDLE_ID="${BUNDLE_ID:-app.sudamp.sudamp}"   # frozen before M8 (DESIGN §13 domain decision)

BIN="$(swift build -c "$CONFIG" --show-bin-path)"
# APP_PATH lets agents and CI build elsewhere without replacing the owner's build/sudamp.app.
APP="${APP_PATH:-$ROOT/build/sudamp.app}"
C="$APP/Contents"
rm -rf "$APP"
mkdir -p "$C/MacOS" "$C/Resources" "$C/Helpers"

cp "$BIN/sudamp" "$C/MacOS/sudamp"
for b in "$BIN"/*.bundle; do
    [ -e "$b" ] && ditto "$b" "$C/Resources/$(basename "$b")"
done
sed -e "s/@VERSION@/$VERSION/g" -e "s/@BUILD@/$BUILD_NUMBER/g" -e "s/@BUNDLE_ID@/$BUNDLE_ID/g" \
    Support/Info.plist.in > "$C/Info.plist"
plutil -lint "$C/Info.plist" >/dev/null
printf 'APPL????' > "$C/PkgInfo"
scripts/make-icon.sh "$C/Resources/AppIcon.icns"
if [ -f catalog/feed.json ]; then cp catalog/feed.json "$C/Resources/feed.json"; fi
# Skins (PLAN M5): sudamp Dark (the default, also built in) and AndAmp Dark/Light (CC BY 4.0, Mattix) with credits.
mkdir -p "$C/Resources/Skins"
for skin in sudamp-dark.wsz AndAmp-Dark.wsz AndAmp-Light.wsz CREDITS.md; do
    cp "Fixtures/skins/$skin" "$C/Resources/Skins/$skin"
done
# Licence, credits and third-party notices (About shows them; DESIGN §10, PLAN M8).
for doc in LICENSE CREDITS.md THIRD_PARTY_NOTICES.md; do cp "$doc" "$C/Resources/$doc"; done
scripts/fetch-qjs.sh "$C/Helpers/qjs"

SIGN=(codesign --force --sign -)
if [ "$HARDENED" = 1 ]; then
    SIGN+=(--options runtime)
    if [ -d "$C/Frameworks" ]; then SIGN+=(--entitlements Support/dev.entitlements); fi
fi
# Inside-out, never --deep: helpers and frameworks first, then the app.
"${SIGN[@]}" "$C/Helpers/qjs"
if [ -d "$C/Frameworks" ]; then
    for f in "$C/Frameworks"/*; do "${SIGN[@]}" "$f"; done
fi
"${SIGN[@]}" "$APP"
codesign --verify --strict "$APP"
echo "built $APP ($CONFIG$([ "$HARDENED" = 1 ] && echo ', hardened'))"
