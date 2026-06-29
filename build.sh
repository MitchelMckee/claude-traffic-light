#!/usr/bin/env bash
# Compile the Swift sources and assemble ClaudeTrafficLight.app (no Xcode).
set -euo pipefail

cd "$(dirname "$0")"

APP="ClaudeTrafficLight"
BUNDLE="build/${APP}.app"
MACOS="${BUNDLE}/Contents/MacOS"
RES="${BUNDLE}/Contents/Resources"

rm -rf build
mkdir -p "$MACOS" "$RES"

echo "==> Compiling Swift sources…"
swiftc -O \
  Sources/*.swift \
  -framework AppKit -framework Foundation \
  -o "${MACOS}/${APP}"

echo "==> Installing Info.plist…"
cp Info.plist "${BUNDLE}/Contents/Info.plist"

# Optional: drop a mascot-mask.png next to this script to override the drawn icon.
if [ -f "mascot-mask.png" ]; then
  cp "mascot-mask.png" "${RES}/mascot-mask.png"
  echo "==> Bundled custom mascot-mask.png"
fi

echo "==> Ad-hoc codesigning (stable identity so TCC grants persist)…"
codesign --force --sign - "$BUNDLE" >/dev/null 2>&1 || \
  echo "    (codesign skipped/failed — app still runs, but Automation prompts may re-ask)"

echo
echo "Built: ${BUNDLE}"
echo "Run:   open \"${BUNDLE}\""
echo "Test:  \"${MACOS}/${APP}\" --selftest"
