#!/usr/bin/env bash
# scripts/fetch-twapi.sh — vendor the twapi extension into .toolchain/ (gitignored).
#
# twapi (Tcl Windows API extension) backs the all-Tcl GUI tooling: window finding,
# OS-level input, and the clipboard read behind tools/shot.tcl.  Version 5.2 ships
# a Tcl 9 / x64 binary that loads into the vendored Tcl 9.0.3 via stubs.
set -euo pipefail

VER=5.2
ZIP=twapi-5.2.0.zip
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/.toolchain/twapi-dl"

if [ -f "$DEST/twapi-5.2.0/pkgIndex.tcl" ]; then
    echo "twapi already vendored at $DEST/twapi-5.2.0"
    exit 0
fi

mkdir -p "$DEST"
cd "$DEST"
echo "Downloading twapi $VER ..."
gh release download "v$VER" -R apnadkarni/twapi -p "$ZIP" --clobber
unzip -o -q "$ZIP"
echo "twapi $VER vendored at $DEST/twapi-5.2.0"
