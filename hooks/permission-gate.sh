#!/usr/bin/env bash
# claude-notify permission gate — PermissionRequest hook
# Sends a rich notification with tool details and waits for remote approval.
# Returns allow/deny programmatically — no keystroke injection needed.
set -euo pipefail

CONFIG_FILE="${HOME}/.config/claude-notify/config"

# Load config
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
else
    exit 0  # No config → don't block
fi

CLAUDE_NOTIFY_SERVER="${CLAUDE_NOTIFY_SERVER:-https://ntfy.sh}"

INPUT="$(cat)"
[[ -z "$INPUT" ]] && exit 0
command -v jq &>/dev/null || exit 0

# --- Parse PermissionRequest payload ---
TOOL_NAME="$(echo "$INPUT" | jq -r '.tool_name // "Unknown"')"
SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // empty')"
HOOK_EVENT="$(echo "$INPUT" | jq -r '.hook_event_name // empty')"

# Build a human-readable description of what Claude wants to do
case "$TOOL_NAME" in
    Bash)
        COMMAND="$(echo "$INPUT" | jq -r '.tool_input.command // empty')"
        DESCRIPTION="$(echo "$INPUT" | jq -r '.tool_input.description // empty')"
        if [[ -n "$DESCRIPTION" ]]; then
            MESSAGE="${DESCRIPTION}\n\n\$ ${COMMAND}"
        else
            MESSAGE="\$ ${COMMAND}"
        fi
        ;;
    Write)
        FILE_PATH="$(echo "$INPUT" | jq -r '.tool_input.file_path // "unknown"')"
        MESSAGE="Create/overwrite file:\n${FILE_PATH}"
        ;;
    Edit)
        FILE_PATH="$(echo "$INPUT" | jq -r '.tool_input.file_path // "unknown"')"
        OLD="$(echo "$INPUT" | jq -r '.tool_input.old_string // "" | .[0:80]')"
        MESSAGE="Edit file: ${FILE_PATH}\nReplace: ${OLD}..."
        ;;
    WebFetch)
        URL="$(echo "$INPUT" | jq -r '.tool_input.url // "unknown"')"
        MESSAGE="Fetch URL:\n${URL}"
        ;;
    Task)
        DESC="$(echo "$INPUT" | jq -r '.tool_input.description // empty')"
        AGENT="$(echo "$INPUT" | jq -r '.tool_input.subagent_type // "unknown"')"
        MESSAGE="Launch ${AGENT} agent: ${DESC}"
        ;;
    mcp__*)
        # MCP tool — show server + tool + first few input fields
        MESSAGE="MCP tool: ${TOOL_NAME}\n$(echo "$INPUT" | jq -r '.tool_input | to_entries[:3] | map("\(.key): \(.value | tostring | .[0:60])") | join("\n")')"
        ;;
    *)
        # Generic: show tool name + first few input fields
        MESSAGE="${TOOL_NAME}: $(echo "$INPUT" | jq -r '.tool_input | to_entries[:3] | map("\(.key): \(.value | tostring | .[0:60])") | join(", ")')"
        ;;
esac

# Resolve project name
PROJECT_DIR="$(echo "$INPUT" | jq -r '.cwd // empty')"
PROJECT_DIR="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-}}"
PROJECT_NAME=""
[[ -n "$PROJECT_DIR" ]] && PROJECT_NAME="$(basename "$PROJECT_DIR")"

TITLE="Allow ${TOOL_NAME}?"
[[ -n "$PROJECT_NAME" ]] && TITLE="[${PROJECT_NAME}] Allow ${TOOL_NAME}?"

# Truncate message
MSG_PLAIN="$(echo -e "$MESSAGE")"
if [[ ${#MSG_PLAIN} -gt 300 ]]; then
    MSG_PLAIN="${MSG_PLAIN:0:297}..."
fi

# --- Register action and send notification ---
CTRL_PORT="${CLAUDE_NOTIFY_PORT:-9876}"
CTRL_LOCAL="http://127.0.0.1:${CTRL_PORT}"
CTRL_REMOTE="${CLAUDE_NOTIFY_REMOTE_URL:-}"
BASE_URL="${CTRL_REMOTE:-${CTRL_LOCAL}}"
ACTION_UUID=""
GATE_MODE="false"

if curl -s -m 1 "${CTRL_LOCAL}/health" >/dev/null 2>&1; then
    ACTION_UUID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    GATE_MODE="true"

    # Register action with server — includes tool details for the control page
    curl -s -m 2 -X POST "${CTRL_LOCAL}/register-action" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg uuid "$ACTION_UUID" \
            --arg sid "$SESSION_ID" \
            --arg ntype "permission_prompt" \
            --arg msg "$MSG_PLAIN" \
            --arg proj "$PROJECT_NAME" \
            --arg tool "$TOOL_NAME" \
            '{ uuid: $uuid, session_id: $sid, notification_type: $ntype,
               message: $msg, project: $proj, tool: $tool }'
        )" >/dev/null 2>&1 || GATE_MODE="false"
fi

# Send ntfy notification
if [[ -n "${CLAUDE_NOTIFY_TOPIC:-}" ]]; then
    CURL_ARGS=(
        -s -m 5
        -H "Title: ${TITLE}"
        -H "Priority: ${CLAUDE_NOTIFY_PRIORITY_PERMISSION:-high}"
        -H "Tags: lock"
    )
    if [[ "$GATE_MODE" == "true" ]]; then
        CURL_ARGS+=(
            -H "Click: ${BASE_URL}/control/${ACTION_UUID}"
            -H "Actions: view, Allow, ${BASE_URL}/approve/${ACTION_UUID}, clear=true; view, Deny, ${BASE_URL}/deny/${ACTION_UUID}, clear=true; view, Details, ${BASE_URL}/control/${ACTION_UUID}"
        )
    fi
    CURL_ARGS+=(-d "${MSG_PLAIN}" "${CLAUDE_NOTIFY_SERVER}/${CLAUDE_NOTIFY_TOPIC}")
    curl "${CURL_ARGS[@]}" >/dev/null 2>&1 &
fi

# Local notification
if [[ "${CLAUDE_NOTIFY_LOCAL:-true}" == "true" ]] && command -v terminal-notifier &>/dev/null; then
    terminal-notifier -title "$TITLE" -message "$MSG_PLAIN" -sound default -group "claude-notify" >/dev/null 2>&1 &
fi

# --- Wait for remote decision (poll the server) ---
# If server is running and action was registered, poll for up to GATE_TIMEOUT seconds.
# The user taps Approve/Deny on their phone → server stores the decision.
GATE_TIMEOUT="${CLAUDE_NOTIFY_GATE_TIMEOUT:-60}"

if [[ "$GATE_MODE" == "true" ]]; then
    ELAPSED=0
    POLL_INTERVAL=2

    while [[ $ELAPSED -lt $GATE_TIMEOUT ]]; do
        RESPONSE="$(curl -s -m 2 "${CTRL_LOCAL}/decision/${ACTION_UUID}" 2>/dev/null || echo "")"
        DECISION="$(echo "$RESPONSE" | jq -r '.decision // empty' 2>/dev/null || echo "")"

        if [[ "$DECISION" == "allow" ]]; then
            # Return programmatic approval
            jq -n '{
                hookSpecificOutput: {
                    hookEventName: "PermissionRequest",
                    decision: { behavior: "allow" }
                }
            }'
            exit 0
        elif [[ "$DECISION" == "deny" ]]; then
            jq -n --arg reason "Denied via claude-notify remote control" '{
                hookSpecificOutput: {
                    hookEventName: "PermissionRequest",
                    decision: { behavior: "deny", message: $reason }
                }
            }'
            exit 0
        fi

        sleep "$POLL_INTERVAL"
        ELAPSED=$((ELAPSED + POLL_INTERVAL))
    done
fi

# Timeout or no server — fall through to normal permission prompt
exit 0
