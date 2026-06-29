#!/usr/bin/env bash
# Start the menubar app at login via a LaunchAgent. Quit from the menu still
# works (KeepAlive is off), it just comes back at the next login.
set -euo pipefail
cd "$(dirname "$0")"

APP_BIN="$(pwd)/build/ClaudeTrafficLight.app/Contents/MacOS/ClaudeTrafficLight"
[ -x "$APP_BIN" ] || { echo "Build first:  ./build.sh"; exit 1; }

LA_DIR="${HOME}/Library/LaunchAgents"
PLIST="${LA_DIR}/com.mitchelmckee.claudetrafficlight.plist"
mkdir -p "$LA_DIR"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.mitchelmckee.claudetrafficlight</string>
  <key>ProgramArguments</key><array><string>${APP_BIN}</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
echo "Installed & loaded: ${PLIST}"
echo "The app will now also start at every login."
