#!/bin/bash
# Fails on any Swift 6 concurrency escape hatch (@unchecked, nonisolated(unsafe), @preconcurrency) that lacks a
# `// SAFETY:` justification on the same or the previous line (DESIGN §4 rules). Prints the total count.
# Usage: scripts/count-escapes.sh [dir ...]   (default: Sources)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DIRS=("$@"); [ ${#DIRS[@]} -eq 0 ] && DIRS=(Sources)
TOTAL=0; BAD=0
while IFS= read -r file; do
    prev=""; n=0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        code="${line%%//*}"   # ignore escapes mentioned inside comments
        if [[ "$code" =~ @unchecked|nonisolated\(unsafe\)|@preconcurrency ]]; then
            TOTAL=$((TOTAL + 1))
            if [[ "$line" != *"// SAFETY:"* && "$prev" != *"// SAFETY:"* ]]; then
                echo "$file:$n: concurrency escape without a '// SAFETY:' comment: ${line#"${line%%[![:space:]]*}"}" >&2
                BAD=$((BAD + 1))
            fi
        fi
        prev="$line"
    done < "$file"
done < <(find "${DIRS[@]}" -name '*.swift' -not -path '*/vendor/*' | sort)
echo "concurrency escapes: $TOTAL total, $BAD unjustified"
[ "$BAD" -eq 0 ]
