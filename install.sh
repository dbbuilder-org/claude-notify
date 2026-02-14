#!/usr/bin/env bash
# claude-notify installer for macOS
# Configures Claude Code hooks to send push notifications via ntfy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${HOME}/.config/claude-notify"
CONFIG_FILE="${CONFIG_DIR}/config"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
HOOK_DIR="${SCRIPT_DIR}/hooks"

echo "============================================"
echo "  claude-notify installer"
echo "  Push notifications for Claude Code"
echo "============================================"
echo ""

# Check dependencies
for cmd in jq curl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: $cmd is required. Install with: brew install $cmd"
        exit 1
    fi
done

# --- Generate or load topic ---
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
    echo "Existing config found: topic = ${CLAUDE_NOTIFY_TOPIC:-<not set>}"
    read -rp "Keep existing config? [Y/n] " keep
    if [[ "${keep,,}" == "n" ]]; then
        CLAUDE_NOTIFY_TOPIC=""
    fi
fi

if [[ -z "${CLAUDE_NOTIFY_TOPIC:-}" ]]; then
    GENERATED_TOPIC="claude-notify-$(openssl rand -hex 6)"
    echo ""
    echo "Generated topic: $GENERATED_TOPIC"
    read -rp "Use this topic? (or type a custom one) [$GENERATED_TOPIC]: " custom_topic
    CLAUDE_NOTIFY_TOPIC="${custom_topic:-$GENERATED_TOPIC}"
fi

CLAUDE_NOTIFY_SERVER="${CLAUDE_NOTIFY_SERVER:-https://ntfy.sh}"

# --- Write config ---
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_FILE" <<EOF
CLAUDE_NOTIFY_TOPIC="${CLAUDE_NOTIFY_TOPIC}"
CLAUDE_NOTIFY_SERVER="${CLAUDE_NOTIFY_SERVER}"
CLAUDE_NOTIFY_PRIORITY_PERMISSION="high"
CLAUDE_NOTIFY_PRIORITY_IDLE="high"
CLAUDE_NOTIFY_PRIORITY_DONE="default"
CLAUDE_NOTIFY_LOCAL="true"
EOF

echo ""
echo "Config written to: $CONFIG_FILE"

# --- Make hook scripts executable ---
chmod +x "${HOOK_DIR}/notify.sh"

# --- Configure Claude Code hooks in settings.json ---
echo ""
echo "Configuring Claude Code hooks..."

mkdir -p "$(dirname "$CLAUDE_SETTINGS")"

# Build the hook script path (absolute)
NOTIFY_SCRIPT="${HOOK_DIR}/notify.sh"

# Create settings.json if it doesn't exist
if [[ ! -f "$CLAUDE_SETTINGS" ]]; then
    echo '{}' > "$CLAUDE_SETTINGS"
fi

# Read existing settings
SETTINGS="$(cat "$CLAUDE_SETTINGS")"

# Build the hook entry (reused across matchers)
HOOK_ENTRY=$(jq -n --arg cmd "bash ${NOTIFY_SCRIPT}" '{
    "type": "command",
    "command": $cmd,
    "timeout": 10
}')

# Merge hooks into settings using the correct Claude Code hooks schema:
# hooks is an object keyed by event name, each value is an array of {matcher?, hooks: [...]}
SETTINGS=$(echo "$SETTINGS" | jq --argjson hook "$HOOK_ENTRY" '
    # Remove any existing claude-notify entries first
    .hooks = ((.hooks // {}) |
        if .Notification then
            .Notification |= map(select(.hooks | all(.command | contains("claude-notify") | not)))
        else . end |
        if .Stop then
            .Stop |= map(select(.hooks | all(.command | contains("claude-notify") | not)))
        else . end
    ) |
    # Add our hooks
    .hooks.Notification = ((.hooks.Notification // []) + [
        { "matcher": "permission_prompt", "hooks": [$hook] },
        { "matcher": "idle_prompt", "hooks": [$hook] },
        { "matcher": "elicitation_dialog", "hooks": [$hook] }
    ]) |
    .hooks.Stop = ((.hooks.Stop // []) + [
        { "hooks": [$hook] }
    ])
')

echo "$SETTINGS" | jq '.' > "$CLAUDE_SETTINGS"
echo "Hooks added to: $CLAUDE_SETTINGS"

# --- Send test notification ---
echo ""
echo "Sending test notification..."
curl -s -m 5 \
    -H "Title: claude-notify installed!" \
    -H "Priority: default" \
    -H "Tags: white_check_mark,tada" \
    -d "Notifications are working. You'll be notified when Claude Code needs attention." \
    "${CLAUDE_NOTIFY_SERVER}/${CLAUDE_NOTIFY_TOPIC}" >/dev/null 2>&1 && \
    echo "Test notification sent!" || \
    echo "Warning: Could not send test notification. Check your network."

# Local notification test
if [[ "${CLAUDE_NOTIFY_LOCAL:-true}" == "true" ]] && command -v terminal-notifier &>/dev/null; then
    terminal-notifier \
        -title "claude-notify installed!" \
        -message "Local notifications are working too." \
        -sound default \
        -group "claude-notify" >/dev/null 2>&1 || true
fi

# --- Print subscription info ---
TOPIC_URL="${CLAUDE_NOTIFY_SERVER}/${CLAUDE_NOTIFY_TOPIC}"
echo ""
echo "============================================"
echo "  Setup complete!"
echo "============================================"
echo ""
echo "Subscribe to notifications on your phone:"
echo ""
echo "  1. Install the ntfy app (iOS/Android)"
echo "  2. Subscribe to this topic:"
echo ""
echo "     ${TOPIC_URL}"
echo ""
echo "  Topic: ${CLAUDE_NOTIFY_TOPIC}"
echo ""
echo "  Or open in browser:"
echo "  ${TOPIC_URL}"
echo ""
echo "Restart Claude Code for hooks to take effect."
echo ""
