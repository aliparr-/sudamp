#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# PROTOTYPE (PLAN M8 licence compliance, DESIGN §10). Lists the corresponding-source archives a sudamp release
# attaches, because libmpv, FFmpeg and MPVKit's other libraries are linked statically:
#   - sudamp's own source at the release tag (vendored mpv headers and scripts included);
#   - MPVKit's build scripts and mpv patches at its pinned tag, and each mpvkit/*-build repository at the tag that
#     produced a linked binary target (the "scripts used to control compilation" the LGPL asks for);
#   - the upstream source archive of every library in THIRD_PARTY_NOTICES.md (one table, owned by
#     scripts/check-notices.sh, so the two cannot drift apart).
#
# It never uploads anything. Attaching the archives to a GitHub Release is M8 work (with the owner's account).
#
# Usage: scripts/mirror-sources.sh [--verify] [--fetch DIR] [--tag TAG]
#   (default)     dry run: print each archive (what, version, URL) and what --fetch would write
#   --verify      HEAD every URL (one at a time, following redirects) and report status and size; downloads nothing
#   --fetch DIR   download into DIR as <key>-<file>, then write DIR/SHA256SUMS; check-notices.sh
#                 --require-sources DIR then confirms nothing is missing
#   --tag TAG     sudamp tag to archive (default: the current commit, labelled "HEAD")
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JQ=/usr/bin/jq
[ -x "$JQ" ] || JQ=jq
MODE=dry
DEST=""
TAG="HEAD"
UA="sudamp-dev mirror-sources (corresponding-source prototype)"
while [ $# -gt 0 ]; do
    case "$1" in
        --verify) MODE=verify; shift ;;
        --fetch) MODE=fetch; DEST="$2"; shift 2 ;;
        --tag) TAG="$2"; shift 2 ;;
        --upload|--publish|--release) echo "mirror-sources: uploading is not implemented (prototype; M8)" >&2; exit 2 ;;
        -h|--help) sed -n '3,22p' "$0"; exit 0 ;;
        *) echo "mirror-sources: unknown argument $1" >&2; exit 2 ;;
    esac
done

MPVKIT_VERSION=$("$JQ" -r '.pins[] | select(.identity == "mpvkit") | .state.version' "$ROOT/Package.resolved")
QJS_VERSION=$(sed -nE 's/^QJS_VERSION="([^"]+)".*/\1/p' "$ROOT/scripts/fetch-qjs.sh")

# key<TAB>version<TAB>url, all archives in one list.
LIST=$( {
    printf 'mpvkit\t%s (build scripts, mpv patches 0001-0003)\thttps://github.com/mpvkit/MPVKit/archive/refs/tags/%s.tar.gz\n' \
        "$MPVKIT_VERSION" "$MPVKIT_VERSION"
    # Each mpvkit/*-build repository at the tag that built a linked binary target ("Built by" in the notices).
    { sed -nE 's/^\| `[^`]+` \| [^|]+ \| [^|]+ \| [^|]+ \| ([A-Za-z0-9_.-]+-build) ([^ |]+) \|.*/\1\t\2/p' \
        "$ROOT/THIRD_PARTY_NOTICES.md" || true; } | sort -u \
        | while IFS=$'\t' read -r repo tag; do
            printf 'mpvkit-%s\t%s (build scripts)\thttps://github.com/mpvkit/%s/archive/refs/tags/%s.tar.gz\n' "$repo" "$tag" "$repo" "$tag"
        done
    "$ROOT/scripts/check-notices.sh" --list-sources
    printf 'quickjs-ng\t%s\thttps://github.com/quickjs-ng/quickjs/archive/refs/tags/%s.tar.gz\n' "$QJS_VERSION" "$QJS_VERSION"
} )

echo "sudamp source: git archive --format=tar.gz --prefix=sudamp-$TAG/ $TAG > sudamp-$TAG-source.tar.gz (local, includes Sources/SudampAO/vendor)"
COUNT=0
FAILED=0
while IFS=$'\t' read -r key version url; do
    [ -n "$key" ] || continue
    COUNT=$((COUNT + 1))
    file="$key-$(basename "$url")"
    case "$MODE" in
        dry)
            printf '%-26s %-58s %s\n' "$key" "$version" "$url"
            ;;
        verify)
            result=$(curl -sS -I -L --max-time 30 -A "$UA" -o /dev/null -w '%{http_code} %{size_download} %{url_effective}' "$url" 2>&1) || true
            status=${result%% *}
            # Some hosts refuse HEAD; ask for the first byte instead.
            if [ "$status" != 200 ]; then
                result=$(curl -sS -L --max-time 30 -A "$UA" -r 0-0 -o /dev/null -w '%{http_code} %{size_download} %{url_effective}' "$url" 2>&1) || true
                status=${result%% *}
            fi
            case "$status" in 200|206) mark=ok ;; *) mark=FAIL; FAILED=$((FAILED + 1)) ;; esac
            printf '%-4s %-26s %s %s\n' "$mark" "$key" "$status" "$url"
            sleep 0.5
            ;;
        fetch)
            mkdir -p "$DEST"
            if [ ! -s "$DEST/$file" ]; then
                curl -fsSL --max-time 600 -A "$UA" -o "$DEST/$file.partial" "$url" && mv "$DEST/$file.partial" "$DEST/$file" \
                    || { echo "mirror-sources: failed $url" >&2; FAILED=$((FAILED + 1)); rm -f "$DEST/$file.partial"; }
                sleep 0.5
            fi
            ;;
    esac
done <<<"$LIST"

if [ "$MODE" = fetch ]; then
    (cd "$DEST" && ls | grep -v -e '^SHA256SUMS$' -e '\.partial$' | xargs shasum -a 256 > SHA256SUMS)
    echo "mirror-sources: $COUNT archives in $DEST ($FAILED failed); SHA256SUMS written. Nothing was uploaded."
elif [ "$MODE" = verify ]; then
    echo "mirror-sources: $COUNT archives, $FAILED unreachable"
else
    echo "mirror-sources: $COUNT archives would be fetched (dry run; --verify checks the URLs, --fetch DIR downloads; nothing is ever uploaded)"
fi
[ "$FAILED" = 0 ]
