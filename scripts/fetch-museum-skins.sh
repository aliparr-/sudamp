#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Puts the Winamp Skin Museum skins listed in Fixtures/skins/museum.json into <dest> as <md5>.wsz, next to a copy of
# museum.json, for scripts/bundle.sh (Contents/Resources/Skins/Museum). The skins are third-party art with no licence
# statement, so the public repository commits only the list, never the files (Fixtures/skins/CREDITS.md).
#
# Files come from the make golden cache (~/Library/Caches/sudamp-dev/golden/skins, or $SUDAMP_GOLDEN_DIR/skins), which
# holds the same skins. Missing ones are downloaded from the museum's r2 bucket one at a time with a pause, using
# golden-fetch.sh's User-Agent etiquette, and checked against their MD5: the museum names each file by the MD5 of its
# bytes. A 403 or 429 stops the run. Nothing downloaded is opened or run here; the app loads skins through SkinKit's
# capped loader.
#
# Usage: scripts/fetch-museum-skins.sh <dest>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIST="$ROOT/Fixtures/skins/museum.json"
CACHE="${SUDAMP_GOLDEN_DIR:-$HOME/Library/Caches/sudamp-dev/golden}/skins"
UA="sudamp-dev-museum/0.1 (bundles a fixed list of skins into the sudamp player; cached; one request at a time)"
JQ=/usr/bin/jq
[ -x "$JQ" ] || JQ=jq

[ $# -eq 1 ] || { echo "usage: $0 <dest>" >&2; exit 2; }
DEST="$1"
mkdir -p "$CACHE" "$DEST"

COPIED=0
DOWNLOADED=0
for md5 in $("$JQ" -r '.skins[].md5' "$LIST"); do
    [[ "$md5" =~ ^[0-9a-f]{32}$ ]] || { echo "fetch-museum-skins: bad md5 '$md5' in $LIST" >&2; exit 1; }
    cached="$CACHE/$md5.wsz"
    if [ ! -f "$cached" ] || [ "$(md5 -q "$cached")" != "$md5" ]; then
        [ "$DOWNLOADED" -gt 0 ] && sleep 1
        part="$cached.part"
        status=$(curl -sS -L -A "$UA" -o "$part" -w '%{http_code}' "https://r2.webampskins.org/skins/$md5.wsz") || status=000
        if [ "$status" != 200 ]; then
            rm -f "$part"
            echo "fetch-museum-skins: HTTP $status for $md5.wsz; stopping (MUSEUM_SKINS=0 builds without them)" >&2
            exit 1
        fi
        if [ "$(md5 -q "$part")" != "$md5" ]; then
            rm -f "$part"
            echo "fetch-museum-skins: $md5.wsz does not match its MD5; stopping" >&2
            exit 1
        fi
        mv "$part" "$cached"
        DOWNLOADED=$((DOWNLOADED + 1))
    fi
    cp "$cached" "$DEST/$md5.wsz"
    COPIED=$((COPIED + 1))
done
cp "$LIST" "$DEST/museum.json"
echo "museum skins: $COPIED copied into $DEST ($DOWNLOADED downloaded)"
