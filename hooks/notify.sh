#!/usr/bin/env bash
# claude-notify hook script for macOS
# Called by Claude Code hooks — reads event JSON from stdin, sends push notification via ntfy.sh
set -euo pipefail

CONFIG_FILE="${HOME}/.config/claude-notify/config"

# Load config
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
else
    echo "claude-notify: config not found at $CONFIG_FILE" >&2
    exit 0  # Don't block Claude Code
fi

# Defaults
CLAUDE_NOTIFY_SERVER="${CLAUDE_NOTIFY_SERVER:-https://ntfy.sh}"
CLAUDE_NOTIFY_LOCAL="${CLAUDE_NOTIFY_LOCAL:-true}"

# Read JSON from stdin
INPUT="$(cat)"

if [[ -z "$INPUT" ]]; then
    exit 0
fi

# Check if jq is available
if ! command -v jq &>/dev/null; then
    echo "claude-notify: jq is required but not installed" >&2
    exit 0
fi

# Parse event fields
EVENT_TYPE="$(echo "$INPUT" | jq -r '.hook_event_name // empty')"
NOTIFICATION_TYPE="$(echo "$INPUT" | jq -r '.notification_type // empty')"
SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // empty')"
MESSAGE="$(echo "$INPUT" | jq -r '.message // "Claude Code needs your attention"')"
TITLE="$(echo "$INPUT" | jq -r '.title // "Claude Code"')"

# Resolve project name from JSON cwd field, env var, or fallback
PROJECT_DIR="$(echo "$INPUT" | jq -r '.cwd // empty')"
PROJECT_DIR="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-}}"
if [[ -n "$PROJECT_DIR" ]]; then
    PROJECT_NAME="$(basename "$PROJECT_DIR")"
else
    PROJECT_NAME=""
fi

# Map notification type to priority and emoji tag
PRIORITY="default"
TAGS="computer"

case "$EVENT_TYPE" in
    Notification)
        case "$NOTIFICATION_TYPE" in
            permission_prompt)
                PRIORITY="${CLAUDE_NOTIFY_PRIORITY_PERMISSION:-high}"
                TAGS="lock"
                TITLE="Permission Required"
                ;;
            idle_prompt)
                PRIORITY="${CLAUDE_NOTIFY_PRIORITY_IDLE:-high}"
                TAGS="hourglass"
                TITLE="Claude Code is Idle"
                ;;
            elicitation_dialog)
                PRIORITY="default"
                TAGS="question"
                TITLE="Claude Code has a Question"
                ;;
            *)
                PRIORITY="default"
                TAGS="bell"
                ;;
        esac
        ;;
    Stop)
        PRIORITY="${CLAUDE_NOTIFY_PRIORITY_DONE:-default}"
        TAGS="white_check_mark"
        TITLE="Task Complete"
        ;;
    *)
        # Unknown event type — still notify
        PRIORITY="default"
        TAGS="bell"
        ;;
esac

# Prepend project name to title
if [[ -n "$PROJECT_NAME" ]]; then
    TITLE="[${PROJECT_NAME}] ${TITLE}"
fi

# Truncate message for notification (keep it readable)
if [[ ${#MESSAGE} -gt 200 ]]; then
    MESSAGE="${MESSAGE:0:197}..."
fi

# --- Remote control integration ---
# If claude-notify-server is running, register a one-time action token
# and include click URL + action buttons in the notification
CTRL_PORT="${CLAUDE_NOTIFY_PORT:-9876}"
CTRL_LOCAL="http://127.0.0.1:${CTRL_PORT}"
CTRL_REMOTE="${CLAUDE_NOTIFY_REMOTE_URL:-}"
CLICK_HEADER=""
ACTIONS_HEADER=""

if curl -s -m 1 "${CTRL_LOCAL}/health" >/dev/null 2>&1; then
    ACTION_UUID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    NOTIFY_TYPE="${NOTIFICATION_TYPE:-stop}"

    # Register action token with server
    curl -s -m 2 -X POST "${CTRL_LOCAL}/register-action" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg uuid "$ACTION_UUID" \
            --arg sid "$SESSION_ID" \
            --arg ntype "$NOTIFY_TYPE" \
            --arg msg "$MESSAGE" \
            --arg proj "$PROJECT_NAME" \
            '{ uuid: $uuid, session_id: $sid, notification_type: $ntype, message: $msg, project: $proj }'
        )" >/dev/null 2>&1 || true

    # Build URLs — use remote URL if configured, otherwise local
    BASE_URL="${CTRL_REMOTE:-${CTRL_LOCAL}}"
    CLICK_HEADER="${BASE_URL}/control/${ACTION_UUID}"
    ACTIONS_HEADER="view, Approve, ${BASE_URL}/approve/${ACTION_UUID}, clear=true; view, Deny, ${BASE_URL}/deny/${ACTION_UUID}, clear=true; view, Open, ${BASE_URL}/control/${ACTION_UUID}"
fi

# Send to ntfy.sh (5-second timeout, non-blocking)
if [[ -n "${CLAUDE_NOTIFY_TOPIC:-}" ]]; then
    CURL_ARGS=(
        -s -m 5
        -H "Title: ${TITLE}"
        -H "Priority: ${PRIORITY}"
        -H "Tags: ${TAGS}"
    )
    [[ -n "$CLICK_HEADER" ]] && CURL_ARGS+=(-H "Click: ${CLICK_HEADER}")
    [[ -n "$ACTIONS_HEADER" ]] && CURL_ARGS+=(-H "Actions: ${ACTIONS_HEADER}")
    CURL_ARGS+=(-d "${MESSAGE}" "${CLAUDE_NOTIFY_SERVER}/${CLAUDE_NOTIFY_TOPIC}")

    curl "${CURL_ARGS[@]}" >/dev/null 2>&1 &
fi

# Local notification via terminal-notifier (if available and enabled)
if [[ "$CLAUDE_NOTIFY_LOCAL" == "true" ]] && command -v terminal-notifier &>/dev/null; then
    terminal-notifier \
        -title "$TITLE" \
        -message "$MESSAGE" \
        -sound default \
        -group "claude-notify" >/dev/null 2>&1 &
fi

# Wait briefly for background processes but don't block
wait -n 2>/dev/null || true

exit 0
