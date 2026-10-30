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
SRC_STATUSLINE="${HERE}/cc-statusline.sh"

CLAUDE_DIR="${HOME}/.claude"
HOOKS_DIR="${CLAUDE_DIR}/hooks"
SETTINGS="${CLAUDE_DIR}/settings.json"
HOOK_DST="${HOOKS_DIR}/cc-hook.sh"
STATUSLINE_DST="${HOOKS_DIR}/cc-statusline.sh"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required (brew install jq)."; exit 2; }
[ -f "$SRC_HOOK" ] || { echo "ERROR: cc-hook.sh not found next to setup-hooks.sh (${SRC_HOOK})."; exit 1; }
[ -f "$SRC_STATUSLINE" ] || { echo "ERROR: cc-statusline.sh not found next to setup-hooks.sh (${SRC_STATUSLINE})."; exit 1; }

echo "==> Installing hook -> ${HOOK_DST}"
mkdir -p "$HOOKS_DIR"
cp "$SRC_HOOK" "$HOOK_DST"
chmod +x "$HOOK_DST"
cp "$SRC_STATUSLINE" "$STATUSLINE_DST"
chmod +x "$STATUSLINE_DST"

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

EVENTS='["UserPromptSubmit","PreToolUse","PermissionRequest","PostToolUse","Notification","Stop","SubagentStop","PreCompact","SessionStart","SessionEnd"]'

tmp="$(mktemp)"
jq --arg cmd "$HOOK_DST" --argjson events "$EVENTS" '
  def cchook($ev):
    if ($ev == "PreToolUse" or $ev == "PermissionRequest" or $ev == "PostToolUse" or $ev == "PreCompact")
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

# --- statusLine: the only place the subscription rate-limit windows surface. --
# Claude Code allows a single statusLine command, so only take the slot when it's
# empty or already ours — never clobber a user's own custom status line.
EXISTING_SL="$(jq -r '.statusLine.command // ""' "$SETTINGS")"
case "$EXISTING_SL" in
  ""|*cc-statusline.sh*)
    slt="$(mktemp)"
    if jq --arg cmd "$STATUSLINE_DST" '.statusLine = {type: "command", command: $cmd}' "$SETTINGS" > "$slt" \
       && jq empty "$slt" >/dev/null 2>&1; then
      mv "$slt" "$SETTINGS"
      echo "==> Wired cc-statusline.sh as your status line (feeds account-usage %)."
    else
      rm -f "$slt"
      echo "WARN: couldn't set the statusLine; account usage won't populate (settings left unchanged)."
    fi ;;
  *)
    echo "==> You already have a custom status line — leaving it untouched."
    echo "    Account-usage % stays blank until cc-statusline.sh sees the payload. To enable it,"
    echo "    have your status line also pipe stdin through: ${STATUSLINE_DST}"
    ;;
esac

echo "==> Done. Start a new Claude Code session to see it report (backup: ${BACKUP})."
