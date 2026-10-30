#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Claude Code menubar traffic-light — account-usage reader (statusLine hook).
#
# Claude Code passes this command the session's statusLine JSON on stdin. That
# payload is the ONLY documented place the subscription rate-limit windows show
# up — `.rate_limits.five_hour` and `.rate_limits.seven_day`, each carrying a
# `used_percentage` (0-100) and `resets_at` (unix epoch). We snapshot those to
#     ${CC_MENUBAR_STATE_DIR:-~/.claude/menubar-state}/usage.json
# for the menubar app to read, and print a compact one-line status back to the
# terminal (model · context% · usage%) so wiring this up ADDS info to the
# prompt rather than blanking the default status line.
#
# Notes:
#   * rate_limits is only present for Claude.ai subscribers, and only after the
#     session's first API response — so on a brand-new session it's absent and
#     we simply don't touch usage.json (the app keeps showing the last snapshot).
#   * The statusLine command runs on every render, so we skip the write when the
#     limit values are unchanged — no needless churn on the app's file watcher.
# ---------------------------------------------------------------------------
set -u

STATE_DIR="${CC_MENUBAR_STATE_DIR:-${HOME}/.claude/menubar-state}"
USAGE_FILE="${STATE_DIR}/usage.json"
PAYLOAD="$(cat)"

# Without jq we can't reliably dig the nested rate_limits out of the payload;
# still print something useful so the status line isn't left blank.
if ! command -v jq >/dev/null 2>&1; then
  printf 'Claude'
  exit 0
fi

# --- pull the fields we care about, all in one jq pass ---------------------
# @sh shell-quotes every value, so this eval is injection-safe.
MODEL=""; CTX=""; H5=""; H5R=""; D7=""; D7R=""
eval "$(printf '%s' "$PAYLOAD" | jq -r '@sh "
  MODEL=\(.model.display_name // "")
  CTX=\(.context_window.used_percentage // "")
  H5=\(.rate_limits.five_hour.used_percentage // "")
  H5R=\(.rate_limits.five_hour.resets_at // "")
  D7=\(.rate_limits.seven_day.used_percentage // "")
  D7R=\(.rate_limits.seven_day.resets_at // "")"' 2>/dev/null)"

# --- snapshot the usage windows for the app (only when present) ------------
if [ -n "$H5" ] || [ -n "$D7" ]; then
  mkdir -p "$STATE_DIR" 2>/dev/null || true

  # Build just the limits object; compare against what's on disk so an
  # unchanged render doesn't rewrite the file (which would wake the watcher).
  LIMITS="$(jq -cn \
    --argjson h5 "${H5:-null}" --argjson h5r "${H5R:-null}" \
    --argjson d7 "${D7:-null}" --argjson d7r "${D7R:-null}" '
    {
      five_hour: (if $h5 == null then null else {used_percentage:$h5, resets_at:$h5r} end),
      seven_day: (if $d7 == null then null else {used_percentage:$d7, resets_at:$d7r} end)
    }' 2>/dev/null)"

  PREV=""
  [ -f "$USAGE_FILE" ] && PREV="$(jq -cS '{five_hour, seven_day}' "$USAGE_FILE" 2>/dev/null || true)"
  CUR="$(printf '%s' "$LIMITS" | jq -cS '.' 2>/dev/null || true)"

  if [ -n "$LIMITS" ] && [ "$CUR" != "$PREV" ]; then
    NOW="$(date +%s)"
    TMP="$(mktemp "${STATE_DIR}/.tmp.XXXXXX" 2>/dev/null)" || TMP=""
    if [ -n "$TMP" ]; then
      trap 'rm -f "$TMP" 2>/dev/null' EXIT
      if printf '%s' "$LIMITS" | jq --argjson now "$NOW" '. + {updatedAt:$now}' > "$TMP" 2>/dev/null; then
        mv -f "$TMP" "$USAGE_FILE" 2>/dev/null    # promote only a fully-written file
      fi
    fi
  fi
fi

# --- print a compact status line back to the terminal ----------------------
line="${MODEL:-Claude}"
[ -n "$CTX" ] && line="${line}  ·  ctx ${CTX}%"
[ -n "$H5" ]  && line="${line}  ·  5h ${H5}%"
[ -n "$D7" ]  && line="${line}  ·  7d ${D7}%"
printf '%s' "$line"
exit 0
