#!/bin/sh
# Regenerates the website's media from the app's own rendering code (see site/tools/SiteMedia.swift):
#   site/media/scenes/  a 4-bar clip (.mp4) and poster (.jpg) of every visualiser scene, plus two with effects (Synthwave with VHS and with Kaleidoscope)
#   site/media/toast/   the Dancing Toast's pixel sprite sheets, poster and manifest
#   site/media/classic/  pictures of the classic skins (render-classic.sh; it also takes reference shots of the modern window into $TMPDIR)
# Builds the tool into /tmp with the pinned Swift (.swift-version), never into the repo. Needs the app built
# (build/sudamp.app) for the analyser frames and the classic/modern pictures.
#
#   site/tools/render-media.sh [scenes|toast|classic|all] (default: all)
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WORK=${SUDAMP_SITE_WORK:-/tmp/sudamp-site}
SWIFTC="$HOME/Library/Developer/Toolchains/swift-$(cat "$ROOT/.swift-version")-RELEASE.xctoolchain/usr/bin/swiftc"
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
APP="$ROOT/build/sudamp.app/Contents/MacOS/sudamp"
TOOL="$WORK/site-media"
FRAMES="$WORK/frames.json"
MEDIA="$ROOT/site/media"
WHAT=${1:-all}

mkdir -p "$WORK"

# The tool: the scene sources plus SiteMedia.swift, as one module.
echo "Building the media tool with $("$SWIFTC" --version 2>&1 | head -1)"
"$SWIFTC" -O -default-isolation MainActor -parse-as-library -sdk "$SDK" -module-name SiteMedia \
    "$ROOT/Sources/ModernUI/ModernTheme.swift" "$ROOT/Sources/ModernUI/ModernPlayerState.swift" \
    $(find "$ROOT/Sources/ModernUI/Visualizer" -name '*.swift' | sort) \
    "$ROOT/site/tools/SiteMedia.swift" -o "$TOOL"

# The analyser's frames of the preview's synthesised music: 32 s at 60 fps.
if [ ! -s "$FRAMES" ]; then
    echo "Dumping analyser frames"
    "$APP" --modern-preview --dump-frames "$FRAMES"
fi

if [ "$WHAT" = all ] || [ "$WHAT" = scenes ]; then
    mkdir -p "$MEDIA/scenes"
    # A few processes at once, each with its share of the clips.
    set -- $("$TOOL" list)
    jobs=6 i=0 pids="" failed=0
    while [ $i -lt $jobs ]; do
        share="" n=0
        for name in "$@"; do
            [ $((n % jobs)) -eq $i ] && share="$share${share:+,}$name"
            n=$((n + 1))
        done
        "$TOOL" scenes --frames "$FRAMES" --out "$MEDIA/scenes" --only "$share" &
        pids="$pids $!"
        i=$((i + 1))
    done
    for pid in $pids; do wait "$pid" || failed=1; done
    # AVAssetWriter can leave a temporary copy behind when the process ends straight after writing.
    rm -f "$MEDIA"/scenes/*.sb-*
    [ $failed -eq 0 ] || { echo "Some clips failed" >&2; exit 1; }
fi

if [ "$WHAT" = all ] || [ "$WHAT" = toast ]; then
    "$TOOL" toast --frames "$FRAMES" --out "$MEDIA/toast"
fi

if [ "$WHAT" = all ] || [ "$WHAT" = classic ]; then
    if [ -x "$ROOT/site/tools/render-classic.sh" ]; then "$ROOT/site/tools/render-classic.sh"; fi
fi

du -sh "$MEDIA"/* 2>/dev/null || true
