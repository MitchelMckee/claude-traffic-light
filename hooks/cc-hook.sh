#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Claude Code menubar traffic-light — per-event state writer.
#
# Wired to every Claude Code hook event. Reads the hook JSON payload on stdin
# and maintains exactly one state file per session at:
#     ${CC_MENUBAR_STATE_DIR:-~/.claude/menubar-state}/<session_id>.json
#
# The menubar app watches that directory and renders an aggregate traffic
# light (green=working, yellow=waiting on you, red=idle). This script is a
# stateless writer: it never sleeps, never blocks, just derives (state,reason)
# from the event and writes a small JSON file atomically.
# ---------------------------------------------------------------------------
set -u

STATE_DIR="${CC_MENUBAR_STATE_DIR:-${HOME}/.claude/menubar-state}"
mkdir -p "$STATE_DIR" 2>/dev/null || true

PAYLOAD="$(cat)"
HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1

# --- parse the hook payload (one jq call, or a sed fallback) ----------------
EVENT=""; SESSION=""; CWD=""; SOURCE=""
if [ "$HAVE_JQ" = 1 ]; then
  # @sh shell-quotes every value, so this eval is injection-safe.
  eval "$(printf '%s' "$PAYLOAD" | jq -r '@sh "EVENT=\(.hook_event_name // "") SESSION=\(.session_id // "") CWD=\(.cwd // "") SOURCE=\(.source // "")"' 2>/dev/null)"
else
  _g() { printf '%s' "$PAYLOAD" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1; }
  EVENT="$(_g hook_event_name)"; SESSION="$(_g session_id)"; CWD="$(_g cwd)"; SOURCE="$(_g source)"
fi

[ -n "$SESSION" ] || exit 0
[ -n "$CWD" ] || CWD="$PWD"
FILE="${STATE_DIR}/${SESSION}.json"

# --- find the long-lived `claude` process PID ------------------------------
# Hooks are spawned by Claude Code, but possibly through a transient shell.
# $PPID may therefore be a shell that exits immediately, so we walk the
# ancestry and pick the first process whose command name ends in "claude".
# If none is found we emit 0, and the app falls back to its orphan TTL sweep
# instead of (wrongly) deleting a live session.
find_claude_pid() {
  local p="$$" c
  while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
    c="$(ps -o comm= -p "$p" 2>/dev/null)"
    case "$c" in
      *claude) printf '%s' "$p"; return 0 ;;
    esac
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
  done
  printf '0'
}
PID="$(find_claude_pid)"

# --- identity / terminal context (for the menu + focus-on-click) -----------
LABEL="${CWD##*/}"; [ -n "$LABEL" ] || LABEL="$CWD"
TP="${TERM_PROGRAM:-}"
TSI="${TERM_SESSION_ID:-}"
ISI="${ITERM_SESSION_ID:-}"
TPANE="${TMUX_PANE:-}"

# --- prior state (idempotency + notification classification) ---------------
PRIOR=""
if [ -f "$FILE" ] && [ "$HAVE_JQ" = 1 ]; then
  PRIOR="$(jq -r '.state // empty' "$FILE" 2>/dev/null || true)"
fi

# --- event -> (state, reason) ----------------------------------------------
# Colors: working=green, permission/finished=yellow, idle=red.
# Exact-name matching means "Stop" never catches "SubagentStop".
STATE=""; REASON=""
case "$EVENT" in
  UserPromptSubmit) STATE="working";  REASON="thinking" ;;
  PreToolUse)       STATE="working";  REASON="running a tool" ;;
  PostToolUse)      STATE="working";  REASON="working" ;;
  PreCompact)       STATE="working";  REASON="compacting context" ;;
  Stop)             STATE="finished"; REASON="finished — your turn" ;;
  SubagentStop)     exit 0 ;;                       # subagent done; main agent still working
  Notification)
    # The Notification event has no machine-readable kind, so we classify by
    # the PRIOR state instead of fragile English-text matching:
    #   - mid-work  -> a permission/confirmation prompt is blocking you   (yellow)
    #   - finished  -> the ~60s "still waiting" idle nudge -> leave the
    #                  finished->idle decay clock running untouched.
    case "$PRIOR" in
      finished)   exit 0 ;;
      permission) exit 0 ;;
      *)          STATE="permission"; REASON="needs your input" ;;
    esac ;;
  SessionStart)
    case "$SOURCE" in
      compact) STATE="working"; REASON="resuming" ;;   # resumed mid-turn after compaction
      *)       STATE="idle";    REASON="ready" ;;       # startup/resume/clear: register, not green
    esac ;;
  SessionEnd)
    rm -f "$FILE" 2>/dev/null || true
    exit 0 ;;
  *) exit 0 ;;
esac

# Idempotency: skip rewriting an unchanged non-working state so its decay
# clock keeps measuring from the original transition. "working" always
# rewrites so updatedAt stays fresh (liveness for the green-staleness timer).
if [ "$STATE" = "$PRIOR" ] && [ "$STATE" != "working" ]; then
  exit 0
fi

# --- atomic write ----------------------------------------------------------
NOW="$(date +%s)"
TMP="$(mktemp "${STATE_DIR}/.tmp.XXXXXX" 2>/dev/null)" || exit 0
trap 'rm -f "$TMP" 2>/dev/null' EXIT          # never leave a temp file behind

ok=0
if [ "$HAVE_JQ" = 1 ]; then
  # jq emits valid JSON for any value (control chars, unicode, quotes).
  if jq -n \
      --arg sessionId "$SESSION" --arg cwd "$CWD" --arg label "$LABEL" \
      --arg state "$STATE" --arg reason "$REASON" --argjson pid "${PID:-0}" \
      --arg terminalProgram "$TP" --arg termSessionId "$TSI" \
      --arg itermSessionId "$ISI" --arg tmuxPane "$TPANE" \
      --arg windowTitle "$LABEL" --argjson updatedAt "$NOW" \
      '{sessionId:$sessionId, cwd:$cwd, label:$label, state:$state, reason:$reason, pid:$pid, terminalProgram:$terminalProgram, termSessionId:$termSessionId, itermSessionId:$itermSessionId, tmuxPane:$tmuxPane, windowTitle:$windowTitle, updatedAt:$updatedAt}' \
      > "$TMP" 2>/dev/null; then ok=1; fi
else
  # Fallback: hand-rolled JSON. esc() covers backslash, quote, tab, CR, and
  # newline so a control char in a path can't produce invalid JSON.
  esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e $'s/\t/\\\\t/g' -e $'s/\r/\\\\r/g' | awk 'NR>1{printf "\\n"} {printf "%s",$0}'; }
  if cat > "$TMP" <<EOF
{
  "sessionId": "$(esc "$SESSION")",
  "cwd": "$(esc "$CWD")",
  "label": "$(esc "$LABEL")",
  "state": "$STATE",
  "reason": "$(esc "$REASON")",
  "pid": ${PID:-0},
  "terminalProgram": "$(esc "$TP")",
  "termSessionId": "$(esc "$TSI")",
  "itermSessionId": "$(esc "$ISI")",
  "tmuxPane": "$(esc "$TPANE")",
  "windowTitle": "$(esc "$LABEL")",
  "updatedAt": ${NOW}
}
EOF
  then ok=1; fi
fi

[ "$ok" = 1 ] && mv -f "$TMP" "$FILE" 2>/dev/null   # promote only a fully-written file
exit 0
