#!/usr/bin/env bash
# Remove the cc-hook wiring from settings.json and delete the hook + state.
set -euo pipefail
cd "$(dirname "$0")"

CLAUDE_DIR="${HOME}/.claude"
SETTINGS="${CLAUDE_DIR}/settings.json"
HOOK_DST="${CLAUDE_DIR}/hooks/cc-hook.sh"
STATE_DIR="${CLAUDE_DIR}/menubar-state"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required."; exit 1; }

if [ -f "$SETTINGS" ] && jq empty "$SETTINGS" >/dev/null 2>&1; then
  BACKUP="${SETTINGS}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$SETTINGS" "$BACKUP"
  tmp="$(mktemp)"
  if jq '
        if .hooks then
          .hooks |= with_entries(
            .value |= map(select(((.hooks // []) | map(.command // "") | any(contains("cc-hook.sh"))) | not))
          )
          # drop now-empty event arrays
          | .hooks |= with_entries(select((.value | length) > 0))
        else . end
      ' "$SETTINGS" > "$tmp" 2>/dev/null && jq empty "$tmp" >/dev/null 2>&1; then
    mv "$tmp" "$SETTINGS"
    echo "==> Removed cc-hook from settings.json (backup: ${BACKUP})"
  else
    rm -f "$tmp"
    echo "WARN: settings rewrite failed; left unchanged (backup: ${BACKUP})"
  fi
fi

rm -f "$HOOK_DST" && echo "==> Removed ${HOOK_DST}" || true
rm -rf "$STATE_DIR" && echo "==> Removed ${STATE_DIR}" || true

PLIST="${HOME}/Library/LaunchAgents/com.mitchelmckee.claude-traffic-light.plist"
if [ -f "$PLIST" ]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "==> Removed login LaunchAgent"
fi

echo "Done. Quit the menubar app from its menu if it is still running."
