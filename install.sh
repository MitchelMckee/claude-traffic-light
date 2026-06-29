#!/usr/bin/env bash
# Install the Claude Code hooks (the menu bar app itself can also do this on
# first launch). This is a thin wrapper around hooks/setup-hooks.sh so there's
# a single source of truth for the wiring logic.
set -euo pipefail
cd "$(dirname "$0")"

hooks/setup-hooks.sh

cat <<EOF

Next:
  ./build.sh && open build/ClaudeTrafficLight.app   # build & launch the menu bar app
  ./autostart.sh                                     # optional: launch at login
EOF
