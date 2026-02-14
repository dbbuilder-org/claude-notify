#!/usr/bin/env bash
# claude-notify interactive configuration
# Generates a topic, tests notifications, shows subscription info
set -euo pipefail

CONFIG_DIR="${HOME}/.config/claude-notify"
CONFIG_FILE="${CONFIG_DIR}/config"

echo "claude-notify configuration"
echo "==========================="
echo ""

# Generate topic
TOPIC="claude-notify-$(openssl rand -hex 6)"
read -rp "Enter ntfy topic [$TOPIC]: " custom
TOPIC="${custom:-$TOPIC}"

# Server
read -rp "Enter ntfy server [https://ntfy.sh]: " server
SERVER="${server:-https://ntfy.sh}"

# Write config
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_FILE" <<EOF
CLAUDE_NOTIFY_TOPIC="${TOPIC}"
CLAUDE_NOTIFY_SERVER="${SERVER}"
CLAUDE_NOTIFY_PRIORITY_PERMISSION="high"
CLAUDE_NOTIFY_PRIORITY_IDLE="high"
CLAUDE_NOTIFY_PRIORITY_DONE="default"
CLAUDE_NOTIFY_LOCAL="true"
EOF

echo ""
echo "Config saved to $CONFIG_FILE"
echo ""

# Test notification
echo "Sending test notification to ${SERVER}/${TOPIC}..."
if curl -s -m 5 \
    -H "Title: claude-notify test" \
    -H "Priority: default" \
    -H "Tags: test_tube" \
    -d "If you see this, notifications are working!" \
    "${SERVER}/${TOPIC}" >/dev/null 2>&1; then
    echo "Test notification sent!"
else
    echo "Warning: could not send notification"
fi

echo ""
echo "Subscribe in the ntfy app: ${SERVER}/${TOPIC}"
echo "Topic: ${TOPIC}"
