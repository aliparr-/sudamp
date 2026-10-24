#!/bin/sh
# Renders the promo site's classic-skin pictures and their manifest (site/media/classic) and the modern window's
# reference captures (in $TMPDIR, not shipped) with the already-built app. Builds nothing; re-run it any time.
#
#   site/tools/render-classic.sh            # both parts
#   site/tools/render-classic.sh classic    # part A only
#   site/tools/render-classic.sh modern     # part B only
#
# A. `sudamp --snapshot` draws each state in site/tools/classic-states offscreen at scale 1 (native skin pixels),
#    through the same SkinKit/SkinUI path as the running app. The manifest takes each skin's 24 visualiser colours
#    from its viscolor.txt (sudamp Dark, the built-in skin, ships the same pixels as Skins/sudamp-dark.wsz), and the
#    script checks every pixel of each main window's visualiser against the drawing rule the manifest describes.
# B. `sudamp --modern-preview --capture` photographs the live modern window (own window only: no Screen Recording
#    permission needed; it works with the screen locked). Captures come out at the display's scale (1x here).
#
# Needs only what macOS has: sh, awk, od, sips, unzip, plutil.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/../.." && pwd -P)
APP="$ROOT/build/sudamp.app/Contents/MacOS/sudamp"
SKINS="$ROOT/build/sudamp.app/Contents/Resources/Skins"
STATES="$HERE/classic-states"
CLASSIC="$ROOT/site/media/classic"
MODERN="${TMPDIR:-/tmp}/sudamp-site-modern"  # reference shots only; the page doesn't use them
PART="${1:-all}"

if [ ! -x "$APP" ]; then
    echo "render-classic: no app at $APP (build it with make first)" >&2
    exit 1
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/render-classic.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT TERM

# Skins: id | display name (SkinLibrary.displayName) | file in Contents/Resources/Skins | credit.
SKIN_TABLE='sudamp-dark|sudamp Dark|sudamp-dark.wsz|
andamp-dark|AndAmp Dark|AndAmp-Dark.wsz|AndAmp skin by Mattix (mattix.nl), CC BY 4.0
andamp-light|AndAmp Light|AndAmp-Light.wsz|AndAmp skin by Mattix (mattix.nl), CC BY 4.0
andamp-spot|AndAmp Spot|AndAmp-Spot.wsz|AndAmp skin by Mattix (mattix.nl), CC BY 4.0'
WINDOWS="main equalizer playlist"

# The 24 viscolor.txt colours of a .wsz as `"#rrggbb", …`, parsed as SkinKit's ViscolorParser does: the n-th line
# starting with three integers sets colour n, channels clamped to 255.
viscolors() {
    unzip -C -p "$1" viscolor.txt | awk '
        {
            sub(/\r$/, "")
            if (match($0, /^[[:space:]]*[0-9]+[[:space:]]*,?[[:space:]]*[0-9]+[[:space:]]*,?[[:space:]]*[0-9]+/)) {
                s = substr($0, RSTART, RLENGTH); gsub(/[^0-9]+/, " ", s); n = split(s, v, " ")
                if (n >= 3 && count < 24) {
                    for (c = 1; c <= 3; c++) { x = substr(v[c], 1, 4) + 0; if (x > 255) x = 255; v[c] = x }
                    printf "%s\"#%02x%02x%02x\"", (count ? ", " : ""), v[1], v[2], v[3]
                    count++
                }
            }
        }
        END { if (count != 24) { print "viscolor.txt has " count " colours, not 24" > "/dev/stderr"; exit 1 } }'
}

# `{"w": 275, "h": 116}` for a PNG.
size_json() {
    sips -g pixelWidth -g pixelHeight "$1" | awk '/pixelWidth/ { w = $2 } /pixelHeight/ { h = $2 }
        END { printf "{\"w\": %d, \"h\": %d}", w, h }'
}

# A state's visualizer.bars or .peaks: `values` prints them as given, `rows` as drawn (round(v × 16), 0…16).
frame_values() {
    plutil -extract "visualizer.$2" json -o - "$1" | tr -d '[]' | awk -F, -v mode="$3" '{
        for (i = 1; i <= NF; i++) {
            v = $i + 0
            if (mode == "rows") printf "%s%d", (i > 1 ? ", " : ""), int(v * 16 + 0.5)
            else printf "%s%.4g", (i > 1 ? ", " : ""), v
        }
    }'
}

# How many of the 76x16 visualiser pixels at (24,43) in a main window's raw RGBA differ from the manifest's rule.
check_visualizer() {  # rgba width "viscolors" "bar rows" "peak rows"
    od -An -v -tu1 "$1" | awk -v W="$2" -v cols="$3" -v bars="$4" -v peaks="$5" '
        { for (k = 1; k <= NF; k++) b[n++] = $k }
        END {
            gsub(/[" ]/, "", cols); split(cols, c, ","); split(bars, bh, ","); split(peaks, ph, ",")
            bad = 0
            for (y = 0; y < 16; y++) for (x = 0; x < 76; x++) {
                idx = (x % 2 == 0 && y % 2 == 1) ? 1 : 0          # background 0, grid dots 1
                i = int(x / 4)
                if (i < 19 && x % 4 < 3) {
                    if (y >= 16 - bh[i + 1]) idx = 2 + y            # bar: row colour
                    if (ph[i + 1] > 0 && y == 16 - ph[i + 1]) idx = 23   # peak
                }
                o = ((43 + y) * W + 24 + x) * 4
                if (sprintf("#%02x%02x%02x", b[o], b[o + 1], b[o + 2]) != c[idx + 1]) bad++
            }
            print bad
        }'
}

render_classic() {
    mkdir -p "$CLASSIC"
    if ! "$APP" --snapshot "$TMP/classic" --states "$STATES"/*.json > "$TMP/report.json"; then
        cat "$TMP/report.json" >&2
        echo "render-classic: the snapshot failed" >&2
        exit 1
    fi
    sample="$STATES/sudamp-dark-main.json"
    bars=$(frame_values "$sample" bars values)
    peaks=$(frame_values "$sample" peaks values)
    bar_rows=$(frame_values "$sample" bars rows)
    peak_rows=$(frame_values "$sample" peaks rows)
    entries=""
    failed=0
    echo "$SKIN_TABLE" | {
        while IFS='|' read -r id name file credit; do
            for w in $WINDOWS; do cp "$TMP/classic/$id-$w.png" "$CLASSIC/$id-$w.png"; done
            # Every state must draw the same frame, or the manifest's sample frame would not match the pictures.
            [ "$(frame_values "$STATES/$id-main.json" bars rows)" = "$bar_rows" ] || { echo "$id: other bars" >&2; exit 1; }
            colors=$(viscolors "$SKINS/$file")
            bad=$(check_visualizer "$TMP/classic/$id-main.rgba" 275 "$colors" "$bar_rows" "$peak_rows")
            echo "render-classic: $id visualiser: $bad of 1216 pixels differ from the manifest's rule" >&2
            [ "$bad" = 0 ] || failed=1
            credit_json=""
            [ -n "$credit" ] && credit_json=", \"credit\": \"$credit\""
            entry=$(printf '    {\n      "id": "%s", "name": "%s"%s,\n      "files": {"main": "%s-main.png", "equalizer": "%s-equalizer.png", "playlist": "%s-playlist.png"},\n      "sizes": {"main": %s, "equalizer": %s, "playlist": %s},\n      "visualizer": {"x": 24, "y": 43, "w": 76, "h": 16},\n      "viscolors": [%s]\n    }' \
                "$id" "$name" "$credit_json" "$id" "$id" "$id" \
                "$(size_json "$CLASSIC/$id-main.png")" "$(size_json "$CLASSIC/$id-equalizer.png")" \
                "$(size_json "$CLASSIC/$id-playlist.png")" "$colors")
            entries="${entries:+$entries,
}$entry"
        done
        [ "$failed" = 0 ] || { echo "render-classic: visualiser check failed" >&2; exit 1; }
        cat > "$CLASSIC/manifest.json" <<EOF
{
  "scale": 1,
  "note": "Classic windows drawn by sudamp --snapshot at scale 1 (one PNG pixel = one skin pixel; upscale with image-rendering: pixelated). All show the same moment: Deep House, Solar Crew - Sunset Sessions playing at 12:34 of 1:02:00, 160 kbps, 48 kHz, stereo, volume 80, EQ preset Dance, the frame below in the visualiser. The AndAmp main and equalizer pictures have transparent rounded corners (alpha 0, from their region.txt); the AndAmp playlists and every sudamp Dark picture are opaque rectangles. States: site/tools/classic-states; script: site/tools/render-classic.sh.",
  "skins": [
$entries
  ],
  "viscolorIndex": {"background": 0, "grid": 1, "spectrumRows": "2-17 (2 = top row, 17 = bottom row)", "oscilloscope": "18-22", "peak": 23},
  "spectrum": {
    "note": "How sudamp draws the classic spectrum (Sources/SkinKit/Render/Visualizer.swift, VisualizerRenderer.draw, after Webamp's Vis.tsx/VisPainter.ts). In the 76x16 visualiser rect: fill with viscolors[0]; put a viscolors[1] grid dot at every even x (0, 2, ..., 74) on every odd y (1, 3, ..., 15). Then for bar i = 0...18 (low to high frequency) at x = 4i, 3 px wide with a 1 px gap (column 75 stays background): the bar fills its bottom h rows, h = round(value * 16) for value 0...1, and screen row r (0 = top, 15 = bottom) is always viscolors[2 + r] - the gradient belongs to the rows, so a short bar shows only the bottom colours. Then if the peak p = round(peak * 16) > 0, a 3 px line at row 16 - p in viscolors[23], drawn over the bar (it replaces the bar's top row when p = h). Bars and peaks are drawn over the grid dots. Redrawn at 30 Hz. Same rect and rule for every skin; only the 24 colours change.",
    "rect": {"x": 24, "y": 43, "w": 76, "h": 16, "source": "MainLayout.visualizer, Sources/SkinKit/Render/Layout.swift; composited there by SkinPicture.composite, Sources/Shell/AppSnapshot.swift"},
    "barCount": 19,
    "barWidth": 3,
    "barGap": 1,
    "barPitch": 4,
    "rows": 16,
    "valueToRows": "rows = round(value * 16), value 0...1 (VisualizerAdapter.barHeight, Sources/SkinUI/SkinPlayerState.swift)",
    "backgroundIndex": 0,
    "gridIndex": 1,
    "gridDots": "even x, odd y, relative to the rect",
    "barColorIndex": "2 + row, row 0 = top ... 15 = bottom",
    "peakIndex": 23,
    "peakRow": "16 - round(peak * 16); no peak when that rounds to 0",
    "fps": 30,
    "falloff": "Bars rise at once and fall 0.75 rows per 30 Hz frame (Winamp 'moderate', 1.40625 full heights a second). A peak jumps up with its bar, then falls, starting at 3/256 row per frame and 1.1 times faster every frame (Sources/Audio/VisualiserAnalyser.swift Settings, after Webamp's VisPainter.ts). Without analyser peaks, SkinUI's PeakTracker holds a peak 8 frames, then drops it 0.5 rows a frame.",
    "analyser": "19 log-spaced bands, 40 Hz-16 kHz, from a 1024-sample Hann-windowed DFT at 48 kHz; -60 dB is an empty bar, -6 dB (re a full-scale sine) a full one.",
    "oscilloscope": "76 samples -1...1, one per column; row = round((1 - (s + 1) / 2) * 15); each column joined vertically to the previous sample's row; colour viscolors[18 + k] with k = 0 on rows 6-7, 1 on 4-5 and 8-9, 2 on 2-3 and 10-11, 3 on 0-1 and 12-13, 4 on 14-15.",
    "frame": {
      "note": "The frame drawn in every *-main.png, from Fixtures/states/app/03-main-playing-youtube-1x.json.",
      "bars": [$bars],
      "peaks": [$peaks],
      "barRows": [$bar_rows],
      "peakRows": [$peak_rows]
    }
  }
}
EOF
    }
    plutil -convert json -o /dev/null "$CLASSIC/manifest.json"
    echo "render-classic: wrote $CLASSIC (12 PNGs, manifest.json)" >&2
}

# One modern capture: name, then preview options. Written only if the capture succeeds. 1.8 s in, the toast is
# dancing and the long title still rests at its start (MarqueeTiming.hold is 2.4 s).
capture_modern() {
    name="$1"; shift
    if "$APP" --modern-preview "$@" --capture-delay 1.8 --capture "$TMP/$name.png" --exit-after 20 \
        > "$TMP/$name.log" 2>&1 && [ -s "$TMP/$name.png" ]; then
        mv "$TMP/$name.png" "$MODERN/$name.png"
        echo "render-classic: $name.png: $(grep 'captured' "$TMP/$name.log" | sed 's/^modern preview: //; s| to [^;]*;|;|')" >&2
    else
        echo "render-classic: $name.png failed:" >&2
        grep -v ' event ' "$TMP/$name.log" | tail -5 >&2
        modern_failed=1
    fi
}

render_modern() {
    mkdir -p "$MODERN"
    modern_failed=0
    capture_modern modern-dark-toast --appearance dark --visualizer toast --backdrop
    capture_modern modern-light-toast --appearance light --visualizer toast --backdrop
    capture_modern modern-dark-panels --appearance dark --visualizer toast --backdrop --panels equalizer,stations
    capture_modern modern-light-panels --appearance light --visualizer toast --backdrop --panels equalizer,stations
    capture_modern modern-dark-nobackdrop --appearance dark --visualizer toast
    [ "$modern_failed" = 0 ] || { echo "render-classic: some modern captures failed" >&2; exit 1; }
}

case "$PART" in
    classic) render_classic ;;
    modern) render_modern ;;
    all) render_classic; render_modern ;;
    *) echo "usage: $0 [classic|modern|all]" >&2; exit 2 ;;
esac
