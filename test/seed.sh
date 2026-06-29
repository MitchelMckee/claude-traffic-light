#!/usr/bin/env bash
# Seed a state directory with sample sessions for testing.
#   CC_MENUBAR_STATE_DIR=/tmp/cc-test ./test/seed.sh
# Then point the app at the same dir:
#   CC_MENUBAR_STATE_DIR=/tmp/cc-test build/ClaudeTrafficLight.app/Contents/MacOS/ClaudeTrafficLight --selftest
set -euo pipefail

DIR="${CC_MENUBAR_STATE_DIR:-${HOME}/.claude/menubar-state}"
mkdir -p "$DIR"
NOW="$(date +%s)"
# A definitely-alive PID for the duration of the test. Defaults to 1 (launchd),
# which also exercises the kill()->EPERM "alive but not ours" branch.
LIVE="${LIVE_PID:-1}"

write() { # 1=id 2=label 3=state 4=reason 5=pid 6=updatedAt 7=term
  cat > "${DIR}/$1.json" <<EOF
{
  "sessionId": "$1", "cwd": "/Users/me/$2", "label": "$2",
  "state": "$3", "reason": "$4", "pid": $5,
  "terminalProgram": "$7", "termSessionId": "", "itermSessionId": "", "tmuxPane": "",
  "windowTitle": "$2", "updatedAt": $6
}
EOF
}

write aaaa1111 api      working    "running a tool"        "$LIVE"  "$NOW"          ghostty
write bbbb2222 web      finished   "finished — your turn"  "$LIVE"  "$((NOW-3))"    ghostty
write cccc3333 infra    permission "needs your input"      "$LIVE"  "$NOW"          iTerm.app
write dddd4444 stale    finished   "finished — your turn"  "$LIVE"  "$((NOW-600))"  ghostty
write eeee5555 crashed  working    "running a tool"        999999   "$NOW"          ghostty

echo "Seeded ${DIR} with 5 sessions (expect 4 live: stale->idle, crashed pruned)."
