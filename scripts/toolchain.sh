#!/bin/bash
# The Swift that sudamp builds with, on every machine and in CI: the version in .swift-version (DESIGN §9). Each Swift
# version gives up type-checking a long expression at a different point, so code that one accepts can fail on another;
# building everywhere with one version stops that. The Makefile uses this; run it alone to see what a build gets.
#   scripts/toolchain.sh       which Swift and SDK a build uses; fails, saying what to install, if it isn't the pinned one
#   scripts/toolchain.sh bin   the pinned swift.org toolchain's bin directory, or nothing to use the system Swift
#   scripts/toolchain.sh sdk   the macOS SDK to build against, or nothing for the default one
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/.swift-version")"
MINOR="$(cut -d. -f1-2 <<< "$VERSION")"
# The newest macOS SDK each Swift reads: an SDK's Swift interfaces need the compiler they shipped with, or a later one.
case "$MINOR" in
    6.2|6.3) SDK_MAJOR=26 ;;
    *) SDK_MAJOR="" ;;
esac

# swift.org packages (and swiftly) install toolchains into one of these, named by version.
toolchain_bin() {
    local dir
    for dir in "$HOME/Library/Developer/Toolchains" /Library/Developer/Toolchains; do
        if [ -x "$dir/swift-$VERSION-RELEASE.xctoolchain/usr/bin/swift" ]; then
            echo "$dir/swift-$VERSION-RELEASE.xctoolchain/usr/bin"
            return
        fi
    done
}

# Nothing when the default SDK will do; otherwise the newest SDK this Swift reads, from the Command Line Tools or Xcode.
sdk() {
    [ -n "$SDK_MAJOR" ] || return 0
    local default dev
    default="$(xcrun --show-sdk-version 2>/dev/null || true)"
    if [ -n "$default" ] && [ "${default%%.*}" -le "$SDK_MAJOR" ]; then return 0; fi
    dev="$(xcode-select -p)"
    ls -d "$dev"/SDKs/MacOSX"$SDK_MAJOR".*.sdk "$dev"/Platforms/MacOSX.platform/Developer/SDKs/MacOSX"$SDK_MAJOR".*.sdk \
        2>/dev/null | sort -V | tail -1 || true
}

check() {
    local bin swift where found sdk_path
    bin="$(toolchain_bin)"
    if [ -n "$bin" ]; then
        swift="$bin/swift"; where="swift.org toolchain"
    else
        swift="$(xcrun -f swift 2>/dev/null || true)"; where="system Swift"
    fi
    found="$([ -n "$swift" ] && "$swift" --version 2>/dev/null |
        sed -nE 's/.*Swift version ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p' | head -1 || true)"
    if [ "$(cut -d. -f1-2 <<< "$found")" != "$MINOR" ]; then
        cat >&2 <<EOF
error: sudamp builds with Swift $VERSION (.swift-version), but the Swift here is ${found:-missing} (${swift:-none}).
Install Swift $VERSION from https://www.swift.org/install/macos/ (its package installs into
~/Library/Developer/Toolchains, where make finds it), or with swiftly (\`swiftly install\` reads .swift-version).
EOF
        exit 1
    fi
    # Xcode's or the Command Line Tools' Swift of the same minor version is near enough to stand in for the exact one.
    [ "$found" = "$VERSION" ] || where="$where, standing in for $VERSION"
    sdk_path="$(sdk)"
    [ -n "$sdk_path" ] || sdk_path="$(xcrun --show-sdk-path)"
    echo "Swift $found ($where: $swift), macOS SDK $(xcrun --sdk "$sdk_path" --show-sdk-version)"
}

case "${1:-check}" in
    bin) toolchain_bin ;;
    sdk) sdk ;;
    check) check ;;
    *) echo "usage: scripts/toolchain.sh [bin|sdk]" >&2; exit 2 ;;
esac
