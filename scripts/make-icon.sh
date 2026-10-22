#!/bin/bash
# Rasterises assets/icon.svg into Support/AppIcon.iconset (10 sizes) with sips, then builds an .icns with iconutil.
# Usage: scripts/make-icon.sh <out.icns>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?usage: make-icon.sh <out.icns>}"
SET="$ROOT/Support/AppIcon.iconset"
SVG="$ROOT/assets/icon.svg"
if [ ! -f "$SET/icon_512x512@2x.png" ] || [ "$SVG" -nt "$SET/icon_512x512@2x.png" ]; then
    mkdir -p "$SET"
    for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x 128:icon_128x128 \
                256:icon_128x128@2x 256:icon_256x256 512:icon_256x256@2x 512:icon_512x512 1024:icon_512x512@2x; do
        px="${spec%%:*}"; name="${spec#*:}"
        sips -s format png -z "$px" "$px" "$SVG" --out "$SET/$name.png" >/dev/null
    done
fi
iconutil -c icns "$SET" -o "$OUT"
