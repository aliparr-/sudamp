#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Scores the museum golden corpus fetched by scripts/golden-fetch.sh (PLAN M4/M7 `make golden`; tracked, not a
# gate): runs the SkinKit test harness `MuseumGoldenHarness` with SKINKIT_GOLDEN=1, which renders every complete
# skin's Main and EQ in Webamp's screenshot state and compares them with the museum screenshots outside the masked
# visualiser, marquee and clock (Tests/SkinKitTests/MuseumGolden.swift). Results go to <dir>/report/:
# summary.md (the numbers docs/measurements.md#golden quotes), report.json (per skin), heat-main.png and
# heat-eq.png (how many skins differ at each pixel) and strips/<worst share>-<md5>.png (screenshot | SkinKit |
# differences, 2x).
#
# Usage: scripts/golden-compare.sh [--scratch-path PATH] [--dir DIR]
#   --scratch-path  SwiftPM scratch path (default .build; agents pass their own)
#   --dir           corpus directory (default ~/Library/Caches/sudamp-dev/golden)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$ROOT/.build"
DIR="${SUDAMP_GOLDEN_DIR:-$HOME/Library/Caches/sudamp-dev/golden}"
while [ $# -gt 0 ]; do
    case "$1" in
        --scratch-path) SCRATCH="$2"; shift 2 ;;
        --dir) DIR="$2"; shift 2 ;;
        -h|--help) sed -n '3,16p' "$0"; exit 0 ;;
        *) echo "golden-compare: unknown argument $1" >&2; exit 2 ;;
    esac
done
if [ ! -s "$DIR/manifest.json" ]; then
    echo "golden-compare: no corpus in $DIR; run scripts/golden-fetch.sh first" >&2
    exit 2
fi
# make passes the plugin path of the Swift it builds with; run alone, the same rule as `make test` for the system Swift.
PLUGINS="${PLUGINS:-$(dirname "$(xcrun -f swift)")/../lib/swift/host/plugins/testing}"
cd "$ROOT"
# Build only SkinKit's tests (the harness needs nothing else), then run the one suite from that build.
{
    swift build --scratch-path "$SCRATCH" --target SkinKitTests -Xswiftc -plugin-path -Xswiftc "$PLUGINS" &&
    SKINKIT_GOLDEN=1 SKINKIT_GOLDEN_DIR="$DIR" swift test --scratch-path "$SCRATCH" --skip-build \
        -Xswiftc -plugin-path -Xswiftc "$PLUGINS" --filter MuseumGoldenHarness
} >"$DIR/compare.log" 2>&1 || {
    tail -40 "$DIR/compare.log" >&2
    exit 1
}
cat "$DIR/report/summary.md"
echo
echo "golden-compare: report in $DIR/report (log: $DIR/compare.log)"
