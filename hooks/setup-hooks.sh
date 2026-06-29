#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Wire cc-hook.sh into ~/.claude/settings.json for every Claude Code session
# event. Idempotent and non-destructive (backs up settings first). Works both
# from the repo (hooks/) and from inside the .app bundle, because it copies
# cc-hook.sh from whatever directory this script lives in.
# ---------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC_HOOK="${HERE}/cc-hook.sh"

CLAUDE_DIR="${HOME}/.claude"
HOOKS_DIR="${CLAUDE_DIR}/hooks"
SETTINGS="${CLAUDE_DIR}/settings.json"
HOOK_DST="${HOOKS_DIR}/cc-hook.sh"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required (brew install jq)."; exit 2; }
[ -f "$SRC_HOOK" ] || { echo "ERROR: cc-hook.sh not found next to setup-hooks.sh (${SRC_HOOK})."; exit 1; }

echo "==> Installing hook -> ${HOOK_DST}"
mkdir -p "$HOOKS_DIR"
cp "$SRC_HOOK" "$HOOK_DST"
chmod +x "$HOOK_DST"

[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
jq empty "$SETTINGS" >/dev/null 2>&1 || { echo "ERROR: ${SETTINGS} is not valid JSON; aborting."; exit 1; }
[ "$(jq -r 'type' "$SETTINGS")" = "object" ] || { echo "ERROR: settings.json top-level must be an object; aborting."; exit 1; }
case "$(jq -r '.hooks | type' "$SETTINGS")" in
  object|null) ;;
  *) echo "ERROR: .hooks must be an object; aborting."; exit 1 ;;
esac

BANNER_BEFORE="$(jq '[.hooks.Notification // [] | .[] | (.hooks // [])[] | .command // "" | select(contains("display notification") and contains("needs your attention"))] | length' "$SETTINGS")"

BACKUP="${SETTINGS}.bak.$(date +%Y%m%d%H%M%S)"
cp "$SETTINGS" "$BACKUP"
echo "==> Backed up settings -> ${BACKUP}"

EVENTS='["UserPromptSubmit","PreToolUse","PostToolUse","Notification","Stop","SubagentStop","PreCompact","SessionStart","SessionEnd"]'

tmp="$(mktemp)"
jq --arg cmd "$HOOK_DST" --argjson events "$EVENTS" '
  def cchook($ev):
    if ($ev == "PreToolUse" or $ev == "PostToolUse" or $ev == "PreCompact")
    then {matcher: "", hooks: [{type: "command", command: $cmd}]}
    else {hooks: [{type: "command", command: $cmd}]}
    end;
  .hooks = (.hooks // {})
  | reduce $events[] as $ev (.;
      .hooks[$ev] = (
        ((.hooks[$ev] // [])
          | map(select(((.hooks // []) | map(.command // "") | any(contains("cc-hook.sh"))) | not))
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

if [ "${BANNER_BEFORE:-0}" -gt 0 ]; then
  echo "==> Replaced your old standalone 'needs your attention' banner (the app owns alerts now)."
fi
echo "==> Done. Start a new Claude Code session to see it report (backup: ${BACKUP})."
