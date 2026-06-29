#!/usr/bin/env bash
# Generate assets/AppIcon.icns from the drawn mascot (run once; the .icns is
# committed and bundled by build.sh).
set -euo pipefail
cd "$(dirname "$0")"

BIN="build/ClaudeTrafficLight.app/Contents/MacOS/ClaudeTrafficLight"
[ -x "$BIN" ] || ./build.sh >/dev/null

WORK="$(mktemp -d)"
MASTER="${WORK}/icon-1024.png"
ICONSET="${WORK}/AppIcon.iconset"
mkdir -p "$ICONSET"

"$BIN" --appicon "$MASTER"

gen() { sips -z "$1" "$1" "$MASTER" --out "${ICONSET}/$2" >/dev/null; }
gen 16   icon_16x16.png
gen 32   icon_16x16@2x.png
gen 32   icon_32x32.png
gen 64   icon_32x32@2x.png
gen 128  icon_128x128.png
gen 256  icon_128x128@2x.png
gen 256  icon_256x256.png
gen 512  icon_256x256@2x.png
gen 512  icon_512x512.png
gen 1024 icon_512x512@2x.png

mkdir -p assets
iconutil -c icns "$ICONSET" -o assets/AppIcon.icns
rm -rf "$WORK"
echo "wrote assets/AppIcon.icns"
