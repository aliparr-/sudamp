#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Plugin-isolation canary (PLAN M0 R1, DESIGN §6.2). Plants a marker-writing yt-dlp extractor plugin in every
# default plugin location yt-dlp 2026.10.21 searches (yt_dlp/plugins.py default_plugin_paths): the user's real
# ~/.config/yt-dlp/plugins, ~/.yt-dlp/plugins, ~/.config/yt-dlp-plugins and ~/yt-dlp-plugins; the same four under
# sudamp's private engine-home; yt-dlp-plugins next to the executable; and the frozen sys.path roots
# (_internal, _internal/lib-dynload). /etc/yt-dlp/plugins and /etc/yt-dlp-plugins need root and are skipped.
#
# Then: (1) positive controls without isolation prove each planted plugin is really loadable; (2) the real
# `sudamp-dev resolve` must write no marker; (3) each isolation layer alone (YTDLP_NO_PLUGINS=1, --no-plugin-dirs)
# must block every location. An EXIT trap removes everything planted (only directories this script created) and
# the script verifies the removal and the engine tree afterwards.
#
# Usage: [CANARY_LOG_DIR=<dir>] run.sh <sudamp-dev binary> <profile dir> <resolve url> <source>
# Prints a JSON summary on stdout; exits 0 only if no marker appeared under isolation and cleanup verified.
set -euo pipefail
DEV="${1:?usage: run.sh <sudamp-dev> <profile> <url> <source>}"
PROFILE="${2:?}"
URL="${3:?}"
SOURCE="${4:?}"
JQ=/usr/bin/jq
CURRENT="$PROFILE/engines/yt-dlp/current.json"
ENGINE_DIR="$PROFILE/engines/yt-dlp/$($JQ -r .directory "$CURRENT")"
EXE="$ENGINE_DIR/$($JQ -r .executable "$CURRENT")"
EH="$PROFILE/engine-home"
MARKERS="$(mktemp -d /tmp/sudamp-canary-markers.XXXXXX)"
WORK="$(mktemp -d /tmp/sudamp-canary-work.XXXXXX)"

# id | package root that receives yt_dlp_plugins/extractor/<module>.py | topmost directory this script creates
LOCATIONS=(
  "user-xdg-plugins|$HOME/.config/yt-dlp/plugins/sudamp-canary|$HOME/.config/yt-dlp"
  "user-dot-plugins|$HOME/.yt-dlp/plugins/sudamp-canary|$HOME/.yt-dlp"
  "user-xdg-yt-dlp-plugins|$HOME/.config/yt-dlp-plugins/sudamp-canary|$HOME/.config/yt-dlp-plugins"
  "user-home-yt-dlp-plugins|$HOME/yt-dlp-plugins/sudamp-canary|$HOME/yt-dlp-plugins"
  "enginehome-xdg-plugins|$EH/.config/yt-dlp/plugins/sudamp-canary|$EH/.config/yt-dlp"
  "enginehome-dot-plugins|$EH/.yt-dlp/plugins/sudamp-canary|$EH/.yt-dlp"
  "enginehome-xdg-yt-dlp-plugins|$EH/.config/yt-dlp-plugins/sudamp-canary|$EH/.config/yt-dlp-plugins"
  "enginehome-home-yt-dlp-plugins|$EH/yt-dlp-plugins/sudamp-canary|$EH/yt-dlp-plugins"
  "exe-dir-yt-dlp-plugins|$ENGINE_DIR/yt-dlp-plugins/sudamp-canary|$ENGINE_DIR/yt-dlp-plugins"
  "syspath-internal|$ENGINE_DIR/_internal|$ENGINE_DIR/_internal/yt_dlp_plugins"
  "syspath-lib-dynload|$ENGINE_DIR/_internal/lib-dynload|$ENGINE_DIR/_internal/lib-dynload/yt_dlp_plugins"
)
CREATED=()

cleanup() {
  local rc=$?
  for top in "${CREATED[@]+"${CREATED[@]}"}"; do rm -rf -- "$top"; done
  if [ -n "${CANARY_LOG_DIR:-}" ]; then mkdir -p "$CANARY_LOG_DIR" && cp "$WORK"/* "$CANARY_LOG_DIR"/ 2>/dev/null; fi
  rm -rf -- "$MARKERS" "$WORK"
  exit $rc
}
trap cleanup EXIT INT TERM HUP

# Refuse to touch anything that already exists: a real user plugin must never be deleted by cleanup.
for loc in "${LOCATIONS[@]}"; do
  IFS='|' read -r id root top <<<"$loc"
  if [ -e "$top" ]; then echo "refusing: $top already exists" >&2; exit 2; fi
done

for loc in "${LOCATIONS[@]}"; do
  IFS='|' read -r id root top <<<"$loc"
  module="sudamp_canary_${id//-/_}"
  mkdir -p "$top"
  CREATED+=("$top")
  mkdir -p "$root/yt_dlp_plugins/extractor"
  cat >"$root/yt_dlp_plugins/extractor/$module.py" <<PY
# sudamp plugin-isolation canary ($id). Writes a marker when imported; planted and removed by run.sh.
import time
with open('$MARKERS/$id', 'a') as f:
    f.write(f'{time.time()}\\n')
from yt_dlp.extractor.common import InfoExtractor
class SudampCanary_${id//-/_}IE(InfoExtractor):
    _VALID_URL = r'sudamp-canary-$id:.+'
    def _real_extract(self, url):
        raise NotImplementedError
PY
done
PLANTED=$(find "${CREATED[@]}" -name 'sudamp_canary_*.py' | wc -l | tr -d ' ')

fired() { ls "$MARKERS" | sort | $JQ -R . | $JQ -s -c .; }
clear_markers() { rm -f "$MARKERS"/*; }
base_env=(HOME="$HOME" PATH=/usr/bin:/bin LANG=en_US.UTF-8 TMPDIR="$PROFILE/Caches/tmp")
private_env=(HOME="$EH" XDG_CONFIG_HOME="$EH/.config" XDG_CACHE_HOME="$PROFILE/Caches/xdg" PATH=/usr/bin:/bin
             LANG=en_US.UTF-8 TMPDIR="$PROFILE/Caches/tmp")
mkdir -p "$PROFILE/Caches/tmp"

# Trigger: an offline probe URL. yt-dlp loads plugins in _real_main before extracting (--list-extractors would
# exit before that); without plugins the generic extractor fails on the unknown scheme without any network.
# 1. Positive controls: no isolation at all, once with the real HOME, once with engine-home.
env -i "${base_env[@]}" "$EXE" --simulate "sudamp-canary-probe:x" >"$WORK/pos-user.txt" 2>&1 || true
POS_USER=$(fired); clear_markers
env -i "${private_env[@]}" "$EXE" --simulate "sudamp-canary-probe:x" >"$WORK/pos-private.txt" 2>&1 || true
POS_PRIVATE=$(fired); clear_markers

# 2. The real resolve, exactly as sudamp runs it (private HOME + YTDLP_NO_PLUGINS=1 + --no-plugin-dirs).
set +e
"$DEV" resolve "$URL" --source "$SOURCE" --profile "$PROFILE" --skip-verify --json >"$WORK/resolve.json" 2>"$WORK/resolve.err"
RESOLVE_RC=$?
set -e
RESOLVE_FIRED=$(fired); clear_markers
RESOLVE_HOST=$($JQ -r '.stream.url // empty' "$WORK/resolve.json" | sed -E 's#^https://([^/]+)/.*#\1#')

# 3. Each layer alone, with the real HOME (the worst case if engine-home were bypassed).
env -i "${base_env[@]}" YTDLP_NO_PLUGINS=1 "$EXE" --ignore-config --simulate "sudamp-canary-probe:x" >"$WORK/env-only.txt" 2>&1 || true
ENV_ONLY=$(fired); clear_markers
env -i "${base_env[@]}" "$EXE" --ignore-config --no-plugin-dirs --simulate "sudamp-canary-probe:x" >"$WORK/flag-only.txt" 2>&1 || true
FLAG_ONLY=$(fired); clear_markers

# Cleanup now (the trap repeats it harmlessly) and verify nothing is left.
for top in "${CREATED[@]}"; do rm -rf -- "$top"; done
LEFT=0
for top in "${CREATED[@]}"; do [ -e "$top" ] && LEFT=$((LEFT + 1)); done
LEFTOVER_FILES=$(find "$EH" "$ENGINE_DIR" -name 'sudamp_canary_*' 2>/dev/null | wc -l | tr -d ' ')
set +e
"$DEV" engine status --profile "$PROFILE" --json >"$WORK/status.json" 2>/dev/null
set -e
TREE_OK=$($JQ -r '.tree | (.missing + .modified + .modeChanged + .unexpected | length) == 0' "$WORK/status.json")

$JQ -n --argjson planted "$PLANTED" --argjson posUser "$POS_USER" --argjson posPrivate "$POS_PRIVATE" \
  --argjson resolveRc "$RESOLVE_RC" --argjson resolveFired "$RESOLVE_FIRED" --arg resolveHost "$RESOLVE_HOST" \
  --argjson envOnly "$ENV_ONLY" --argjson flagOnly "$FLAG_ONLY" --argjson leftDirs "$LEFT" \
  --argjson leftFiles "$LEFTOVER_FILES" --argjson treeOk "$TREE_OK" \
  --arg skipped "/etc/yt-dlp/plugins, /etc/yt-dlp-plugins (need root)" \
  '{planted: $planted, positiveControlRealHome: $posUser, positiveControlEngineHome: $posPrivate,
    resolveExit: $resolveRc, resolveMediaHost: $resolveHost, resolveMarkers: $resolveFired,
    envOnlyMarkers: $envOnly, flagOnlyMarkers: $flagOnly, skipped: $skipped,
    cleanup: {dirsLeft: $leftDirs, canaryFilesLeft: $leftFiles, engineTreeOk: $treeOk},
    pass: ($resolveRc == 0 and ($resolveFired|length) == 0 and ($envOnly|length) == 0 and ($flagOnly|length) == 0
           and $leftDirs == 0 and $leftFiles == 0 and $treeOk)}'
[ "$RESOLVE_RC" -eq 0 ] && [ "$RESOLVE_FIRED" = "[]" ] && [ "$ENV_ONLY" = "[]" ] && [ "$FLAG_ONLY" = "[]" ] \
  && [ "$LEFT" -eq 0 ] && [ "$LEFTOVER_FILES" -eq 0 ] && [ "$TREE_OK" = "true" ]
