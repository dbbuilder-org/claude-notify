#!/usr/bin/env bash
# Unregister this Claude Code session from claude-notify-server
# Called by the SessionEnd hook
set -euo pipefail

SERVER_PORT="${CLAUDE_NOTIFY_PORT:-9876}"
SERVER_URL="http://127.0.0.1:${SERVER_PORT}"

INPUT="$(cat)"
[[ -z "$INPUT" ]] && exit 0

command -v jq &>/dev/null || exit 0

SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // empty')"
[[ -z "$SESSION_ID" ]] && exit 0

curl -s -m 2 -X DELETE "${SERVER_URL}/session/${SESSION_ID}" >/dev/null 2>&1 || true

exit 0
