#!/usr/bin/env bash
# Register this Claude Code session + iTerm2 session with claude-notify-server
# Called by the SessionStart hook
set -euo pipefail

SERVER_PORT="${CLAUDE_NOTIFY_PORT:-9876}"
SERVER_URL="http://127.0.0.1:${SERVER_PORT}"

INPUT="$(cat)"

if [[ -z "$INPUT" ]]; then
    exit 0
fi

# jq required
command -v jq &>/dev/null || exit 0

SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // empty')"
CWD="$(echo "$INPUT" | jq -r '.cwd // empty')"

# iTerm2 sets this env var in each pane
ITERM_SESSION="${ITERM_SESSION_ID:-}"

if [[ -z "$SESSION_ID" ]]; then
    exit 0
fi

# Register with server (non-blocking, best-effort)
curl -s -m 2 -X POST "${SERVER_URL}/session" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
        --arg sid "$SESSION_ID" \
        --arg iterm "$ITERM_SESSION" \
        --arg cwd "$CWD" \
        '{ session_id: $sid, iterm_session: $iterm, cwd: $cwd }'
    )" >/dev/null 2>&1 || true

exit 0
