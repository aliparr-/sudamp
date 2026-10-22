#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Fetches the museum golden corpus (PLAN M4/M7 `make golden`, tracked, not a gate): about 100 *complete* classic
# skins (every core sheet present, so Webamp never drew its Nullsoft base skin where sudamp would draw sudamp
# Dark) plus their Skin Museum screenshots (275x348 PNGs rendered by Webamp in its fixed screenshot state).
#
# Source: the Winamp Skin Museum's GraphQL API (POST https://api.webamp.org/graphql, no auth; docs/research/
# skins.md). Etiquette: a descriptive User-Agent (r2.webampskins.org refuses some default ones), one request at a
# time with a pause between requests, and everything cached: listing pages, archives and screenshots are fetched
# once and reused, and the selection is pinned in manifest.json. A 403 or 429 stops the run.
#
# Downloads land in ~/Library/Caches/sudamp-dev/golden/ (never the app's own caches) and are only ever read as
# data by the compare harness (scripts/golden-compare.sh); nothing in them is executed.
#
# Usage: scripts/golden-fetch.sh [--count N] [--pages N] [--dir DIR] [--delay SECONDS] [--refresh] [--dry-run]
#   --count    skins to select (default 100)
#   --pages    listing pages of 50 spread evenly across the museum (default 16)
#   --refresh  re-select from the cached pages (the manifest is otherwise reused as is)
#   --dry-run  list what would be selected and downloaded; fetch only missing listing pages
set -euo pipefail

COUNT=100
PAGES=16
PAGE_SIZE=50
DIR="${SUDAMP_GOLDEN_DIR:-$HOME/Library/Caches/sudamp-dev/golden}"
DELAY=1
REFRESH=0
DRY_RUN=0
API="https://api.webamp.org/graphql"
UA="sudamp-dev-golden/0.1 (skin-compatibility metric for the sudamp player; cached; one request at a time)"
JQ=/usr/bin/jq
[ -x "$JQ" ] || JQ=jq

while [ $# -gt 0 ]; do
    case "$1" in
        --count) COUNT="$2"; shift 2 ;;
        --pages) PAGES="$2"; shift 2 ;;
        --dir) DIR="$2"; shift 2 ;;
        --delay) DELAY="$2"; shift 2 ;;
        --refresh) REFRESH=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) sed -n '3,22p' "$0"; exit 0 ;;
        *) echo "golden-fetch: unknown argument $1" >&2; exit 2 ;;
    esac
done

case "$DIR" in
    */Library/Caches/sudamp|*/Library/Caches/sudamp/*|*/Application\ Support/sudamp*)
        echo "golden-fetch: refusing to write into the app's own folders ($DIR)" >&2; exit 2 ;;
esac
mkdir -p "$DIR/pages" "$DIR/skins" "$DIR/screenshots"

REQUESTS=0
pause() { REQUESTS=$((REQUESTS + 1)); sleep "$DELAY"; }

# POST a GraphQL query; writes the response to $2. Stops on HTTP errors.
graphql() {
    local query="$1" out="$2" body status
    body=$("$JQ" -n --arg q "$query" '{query: $q}')
    status=$(curl -sS -o "$out.partial" -w '%{http_code}' --max-time 60 -A "$UA" \
        -H 'content-type: application/json' --data "$body" "$API") || status=000
    pause
    if [ "$status" != 200 ]; then
        rm -f "$out.partial"
        echo "golden-fetch: GraphQL answered HTTP $status; stopping" >&2
        exit 3
    fi
    if [ "$("$JQ" -r 'has("errors")' "$out.partial")" = true ]; then
        "$JQ" -c '.errors' "$out.partial" >&2
        rm -f "$out.partial"
        exit 3
    fi
    mv "$out.partial" "$out"
}

# Museum size, cached with the first page so offsets stay stable between runs.
COUNT_FILE="$DIR/pages/count.json"
if [ ! -s "$COUNT_FILE" ]; then
    graphql '{ skins(first: 1, offset: 0) { count } }' "$COUNT_FILE"
fi
TOTAL=$("$JQ" -r '.data.skins.count' "$COUNT_FILE")
SPAN=$((TOTAL - PAGE_SIZE))

PAGE_FILES=()
for ((i = 0; i < PAGES; i++)); do
    offset=$((i * SPAN / PAGES))
    file="$DIR/pages/offset-$offset.json"
    if [ ! -s "$file" ]; then
        graphql "{ skins(first: $PAGE_SIZE, offset: $offset) { nodes { md5 filename download_url screenshot_url nsfw archive_files { filename } } } }" "$file"
    fi
    PAGE_FILES+=("$file")
done

MANIFEST="$DIR/manifest.json"
if [ "$REFRESH" = 1 ] || [ ! -s "$MANIFEST" ]; then
    per_page=$(((COUNT + PAGES - 1) / PAGES))
    # Complete = every sheet Main, EQ and Playlist draw (gen.bmp is in ~10% of skins and not drawn), with either
    # digit set. Names match Webamp's rule: any folder, any case, .bmp or .png.
    "$JQ" -s --argjson per "$per_page" --argjson count "$COUNT" --argjson total "$TOTAL" '
        def base: ascii_downcase | split("/") | last | split("\\") | last;
        def has($names; $n): ($names | index($n + ".bmp")) != null or ($names | index($n + ".png")) != null;
        def complete:
            ([.archive_files[]?.filename | base]) as $f
            | all(["main", "cbuttons", "titlebar", "shufrep", "posbar", "volume", "balance", "monoster",
                   "playpaus", "text", "eqmain", "eq_ex", "pledit"][]; has($f; .))
              and (has($f; "numbers") or has($f; "nums_ex"));
        [ .[] | [.data.skins.nodes[] | select(.nsfw == false and complete)] | .[0:$per] ]
        | flatten | .[0:$count]
        | { museumCount: $total, selected: length,
            skins: map({ md5, filename, download_url, screenshot_url,
                         wsz: ("skins/" + .md5 + ".wsz"), png: ("screenshots/" + .md5 + ".png") }) }
    ' "${PAGE_FILES[@]}" > "$MANIFEST.partial"
    mv "$MANIFEST.partial" "$MANIFEST"
fi

SELECTED=$("$JQ" -r '.selected' "$MANIFEST")
echo "golden-fetch: $SELECTED complete skins selected from $PAGES pages of $PAGE_SIZE (museum: $TOTAL skins)"

# Download one URL to a cached path, checking the file signature (hex). Returns 1 on a soft failure.
fetch() {
    local url="$1" dest="$2" magic="$3" status
    [ -s "$dest" ] && return 0
    case "$url" in https://r2.webampskins.org/*) ;; *) echo "golden-fetch: unexpected host in $url" >&2; return 1 ;; esac
    if [ "$DRY_RUN" = 1 ]; then echo "would fetch $url"; return 0; fi
    status=$(curl -sS -L -o "$dest.partial" -w '%{http_code}' --max-time 60 -A "$UA" "$url") || status=000
    pause
    case "$status" in
        200) ;;
        403|429) rm -f "$dest.partial"; echo "golden-fetch: HTTP $status from $url; stopping" >&2; exit 3 ;;
        *) rm -f "$dest.partial"; echo "golden-fetch: HTTP $status from $url (skipped)" >&2; return 1 ;;
    esac
    if [ "$(xxd -p -l $((${#magic} / 2)) "$dest.partial")" != "$magic" ]; then
        rm -f "$dest.partial"; echo "golden-fetch: $url has an unexpected signature (skipped)" >&2; return 1
    fi
    mv "$dest.partial" "$dest"
}

FAILED=0
while IFS=$'\t' read -r md5 wsz_url png_url; do
    fetch "$wsz_url" "$DIR/skins/$md5.wsz" 504b || FAILED=$((FAILED + 1))
    fetch "$png_url" "$DIR/screenshots/$md5.png" 89504e47 || FAILED=$((FAILED + 1))
done < <("$JQ" -r '.skins[] | [.md5, .download_url, .screenshot_url] | @tsv' "$MANIFEST")

HAVE=$("$JQ" -r '.skins[] | .md5' "$MANIFEST" | while read -r md5; do
    [ -s "$DIR/skins/$md5.wsz" ] && [ -s "$DIR/screenshots/$md5.png" ] && echo "$md5"
done | wc -l | tr -d ' ')
echo "golden-fetch: $HAVE/$SELECTED skins with screenshots in $DIR ($REQUESTS requests this run, $FAILED failures)"
