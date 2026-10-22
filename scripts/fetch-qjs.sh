#!/bin/bash
# Fetches the pinned QuickJS-NG `qjs` (MIT) used as yt-dlp's JS-runtime fallback (DESIGN §6.2 tier 2) and copies
# it to the given path. Cached in ~/Library/Caches/sudamp-dev. Usage: scripts/fetch-qjs.sh <dest>
set -euo pipefail
QJS_VERSION="v0.17.0"
QJS_ASSET="qjs-darwin-arm64"
QJS_SHA256="8be3ddfe3397d2e692e4e1e8972ee9d032a0a580505d2f8b4ea528cf1b651c11"
DEST="${1:?usage: fetch-qjs.sh <dest>}"
CACHE="${SUDAMP_DEV_CACHE:-$HOME/Library/Caches/sudamp-dev}/qjs-$QJS_VERSION"
mkdir -p "$CACHE"
if [ ! -f "$CACHE/$QJS_ASSET" ] || ! echo "$QJS_SHA256  $CACHE/$QJS_ASSET" | shasum -a 256 -c - >/dev/null 2>&1; then
    curl -fsSL -o "$CACHE/$QJS_ASSET.partial" \
        "https://github.com/quickjs-ng/quickjs/releases/download/$QJS_VERSION/$QJS_ASSET"
    echo "$QJS_SHA256  $CACHE/$QJS_ASSET.partial" | shasum -a 256 -c - >/dev/null
    mv "$CACHE/$QJS_ASSET.partial" "$CACHE/$QJS_ASSET"
fi
mkdir -p "$(dirname "$DEST")"
cp "$CACHE/$QJS_ASSET" "$DEST"
chmod 755 "$DEST"
