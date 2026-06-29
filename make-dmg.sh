#!/usr/bin/env bash
# Package the built app into a drag-to-Applications .dmg (build/<App>-<ver>.dmg).
# Uses hdiutil (built in, reliable, no GUI scripting).
set -euo pipefail
cd "$(dirname "$0")"

APP="ClaudeTrafficLight"
BUNDLE="build/${APP}.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist 2>/dev/null || echo 1.0.0)"
DMG="build/${APP}-${VERSION}.dmg"

[ -d "$BUNDLE" ] || ./build.sh >/dev/null
rm -f "$DMG"

STAGE="$(mktemp -d)/stage"
mkdir -p "$STAGE"
cp -R "$BUNDLE" "$STAGE/"
ln -s /Applications "$STAGE/Applications"        # drag-to-install target

hdiutil create \
  -volname "$APP" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov "$DMG" >/dev/null
rm -rf "$(dirname "$STAGE")"

echo "Built: $DMG  ($(du -h "$DMG" | cut -f1))"
shasum -a 256 "$DMG" | awk '{print "sha256: " $1}'
