#!/bin/bash
# Fails if a build log contains a warning that is not matched by Support/warnings-allowlist.txt (DESIGN §9).
# Usage: scripts/check-warnings.sh <build-log>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="${1:?usage: check-warnings.sh <build-log>}"
ALLOW="$ROOT/Support/warnings-allowlist.txt"
PATTERNS="$(mktemp)"; trap 'rm -f "$PATTERNS"' EXIT
grep -vE '^\s*(#|$)' "$ALLOW" > "$PATTERNS" || true
# Strip ANSI colour codes before matching.
WARNINGS="$(sed -E $'s/\x1b\\[[0-9;]*m//g' "$LOG" | grep -E 'warning:' | sort -u || true)"
[ -z "$WARNINGS" ] && exit 0
if [ -s "$PATTERNS" ]; then
    UNEXPECTED="$(printf '%s\n' "$WARNINGS" | grep -vEf "$PATTERNS" || true)"
else
    UNEXPECTED="$WARNINGS"
fi
if [ -n "$UNEXPECTED" ]; then
    echo "error: build produced warnings not in Support/warnings-allowlist.txt:" >&2
    printf '%s\n' "$UNEXPECTED" >&2
    exit 1
fi
