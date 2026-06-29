#!/usr/bin/env bash
# Install the hook script and wire it into ~/.claude/settings.json for every
# session event. Idempotent and non-destructive: backs up settings first and
# preserves any unrelated hooks.
set -euo pipefail
cd "$(dirname "$0")"

CLAUDE_DIR="${HOME}/.claude"
HOOKS_DIR="${CLAUDE_DIR}/hooks"
SETTINGS="${CLAUDE_DIR}/settings.json"
HOOK_DST="${HOOKS_DIR}/cc-hook.sh"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required (brew install jq)."; exit 1; }

echo "==> Installing hook -> ${HOOK_DST}"
mkdir -p "$HOOKS_DIR"
cp hooks/cc-hook.sh "$HOOK_DST"
chmod +x "$HOOK_DST"

[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
jq empty "$SETTINGS" >/dev/null 2>&1 || { echo "ERROR: ${SETTINGS} is not valid JSON; aborting."; exit 1; }

# Guard the shapes the merge assumes, so we fail clearly instead of with a
# cryptic jq error on an unusual settings file.
[ "$(jq -r 'type' "$SETTINGS")" = "object" ] || { echo "ERROR: settings.json top-level must be an object; aborting."; exit 1; }
case "$(jq -r '.hooks | type' "$SETTINGS")" in
  object|null) ;;
  *) echo "ERROR: .hooks must be an object; aborting."; exit 1 ;;
esac

# Did a legacy standalone banner exist? (controls the closing message)
BANNER_BEFORE="$(jq '[.hooks.Notification // [] | .[] | (.hooks // [])[] | .command // "" | select(contains("display notification") and contains("needs your attention"))] | length' "$SETTINGS")"

BACKUP="${SETTINGS}.bak.$(date +%Y%m%d%H%M%S)"
cp "$SETTINGS" "$BACKUP"
echo "==> Backed up settings -> ${BACKUP}"

EVENTS='["UserPromptSubmit","PreToolUse","PostToolUse","Notification","Stop","SubagentStop","PreCompact","SessionStart","SessionEnd"]'

tmp="$(mktemp)"
jq --arg cmd "$HOOK_DST" --argjson events "$EVENTS" '
  # Tool/compaction events use a matcher; pass "" to match all. Other events
  # have no matcher concept, so omit it.
  def cchook($ev):
    if ($ev == "PreToolUse" or $ev == "PostToolUse" or $ev == "PreCompact")
    then {matcher: "", hooks: [{type: "command", command: $cmd}]}
    else {hooks: [{type: "command", command: $cmd}]}
    end;
  .hooks = (.hooks // {})
  | reduce $events[] as $ev (.;
      .hooks[$ev] = (
        ((.hooks[$ev] // [])
          # drop any previous cc-hook group (idempotent re-install)
          | map(select(((.hooks // []) | map(.command // "") | any(contains("cc-hook.sh"))) | not))
          # for Notification, also drop the legacy standalone banner COMMAND
          # (not the whole group — preserve any sibling hooks), then drop groups
          # left empty. The app owns alerts now.
          | if $ev == "Notification"
            then ( map(.hooks = ((.hooks // [])
                     | map(select(((.command // "")
                         | (contains("display notification") and contains("needs your attention"))) | not))))
                   | map(select((.hooks | length) > 0)) )
            else . end
        ) + [cchook($ev)]
      )
    )
' "$SETTINGS" > "$tmp"

if jq empty "$tmp" >/dev/null 2>&1; then
  mv "$tmp" "$SETTINGS"
  echo "==> Wired cc-hook.sh into all session events."
else
  rm -f "$tmp"
  echo "ERROR: merge produced invalid JSON; settings left unchanged."; exit 1
fi

echo
echo "Done."
echo "  • New Claude Code sessions report state immediately (restart any running ones)."
if [ "${BANNER_BEFORE:-0}" -gt 0 ]; then
  echo "  • Removed your existing \"needs your attention\" Notification banner so you"
  echo "    don't get a duplicate alert; the app now owns notifications."
  echo "    Restore it from: ${BACKUP}"
fi
echo "  • Build & launch the app:"
echo "        ./build.sh && open build/ClaudeTrafficLight.app"
echo "  • Start it automatically at login:"
echo "        ./autostart.sh"
echo "  • Settings backup: ${BACKUP}"
