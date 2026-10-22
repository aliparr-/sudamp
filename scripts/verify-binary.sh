#!/bin/bash
# Build-time guard that the link-time pull-AO override took effect and the bundle is sane (DESIGN §5.3).
# Usage: scripts/verify-binary.sh [path/to/sudamp.app]
set -euo pipefail
export LC_ALL=C
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/sudamp.app}"
EXE="$APP/Contents/MacOS/sudamp"
MAP="$ROOT/.build/sudamp-link.map"
fail() { echo "verify-binary: FAIL: $*" >&2; exit 1; }

[ -x "$EXE" ] || fail "$EXE missing (run make app)"

# 1. Our driver is linked; mpv's ao_pcm file writer is not.
strings "$EXE" | grep -F "sudamp pull AO" >/dev/null || fail "'sudamp pull AO' not found in binary"
if strings "$EXE" | grep -F "RAW PCM/WAVE file writer" >/dev/null; then fail "mpv's ao_pcm file writer is linked"; fi

# 2. The linker map attributes _audio_out_pcm to sudamp_ao.o and loads no ao_pcm archive member.
[ -f "$MAP" ] || fail "linker map $MAP missing"
[ "$MAP" -nt "$EXE" ] || [ "$(stat -f %m "$MAP")" -ge "$(( $(stat -f %m "$EXE") - 5 ))" ] || fail "linker map is older than the binary"
IDX="$(awk '/^# Symbols:/{s=1;next} s && $NF=="_audio_out_pcm"{for(i=1;i<=NF;i++) if($i ~ /^\[/){g=$i; if($(i+1) ~ /\]$/) g=g $(i+1); gsub(/[\[\] ]/,"",g); print g; exit}}' "$MAP")"
[ -n "$IDX" ] || fail "_audio_out_pcm not found in linker map"
OBJ="$(awk -v idx="$IDX" '/^# Object files:/{s=1;next} /^# /{if(s)exit} s{line=$0; gsub(/^\[ */,"",line); split(line,a,"]"); if(a[1]==idx){sub(/^[^]]*\] */,"",$0); print; exit}}' "$MAP")"
case "$OBJ" in *sudamp_ao*|*/SudampAO.o|*/SudampAO.build/*) ;; *) fail "_audio_out_pcm comes from '$OBJ', expected the SudampAO object" ;; esac
if grep -qE "audio_out_ao_pcm\.c\.o|\(ao_pcm\.c\.o\)" "$MAP"; then fail "an ao_pcm archive member was loaded"; fi

# 3. Only system libraries (plus Sparkle once embedded in M8).
BAD="$(otool -L "$EXE" | tail -n +2 | awk '{print $1}' | grep -vE '^(/System/Library/|/usr/lib/|@rpath/Sparkle\.framework/Versions/B/Sparkle$)' || true)"
[ -z "$BAD" ] || fail "unexpected linked libraries: $BAD"

# 4. Signature.
codesign --verify --strict "$APP" || fail "codesign --verify --strict"
echo "verify-binary: OK (_audio_out_pcm from $(basename "$OBJ"); system libraries only; signature valid)"
