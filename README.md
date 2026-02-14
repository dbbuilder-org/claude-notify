# claude-notify

Push notifications for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) via [ntfy.sh](https://ntfy.sh).

Get notified on your phone/desktop whenever Claude Code needs your attention — permission prompts, idle waiting, task completion, or questions.

## Features

- **Cross-platform**: macOS and Windows support
- **Push notifications** via ntfy.sh (free, no account required)
- **Local notifications** as fallback (terminal-notifier on macOS, BurntToast on Windows)
- **Priority-based**: permission prompts are high priority, completions are normal
- **Non-blocking**: 5-second timeout, won't slow down Claude Code
- **Easy setup**: one-command installer configures everything

## Quick Start

### macOS

```bash
git clone <repo-url> ~/dev2/claude-notify
cd ~/dev2/claude-notify
bash install.sh
```

### Windows

```powershell
git clone <repo-url> ~/dev2/claude-notify
cd ~/dev2/claude-notify
.\install.ps1
```

### Subscribe on Your Phone

1. Install the [ntfy app](https://ntfy.sh) on your phone (iOS/Android)
2. Subscribe to the topic shown during installation
3. Done — you'll get push notifications whenever Claude Code needs attention

## Hook Events

| Event | Type | Priority | Emoji |
|-------|------|----------|-------|
| Permission prompt | `Notification` | High (4) | Lock |
| Idle prompt | `Notification` | High (4) | Hourglass |
| Question/elicitation | `Notification` | Default (3) | Question |
| Task complete | `Stop` | Default (3) | Check mark |

## Configuration

Config is stored at `~/.config/claude-notify/config` (macOS) or `%USERPROFILE%\.config\claude-notify\config.ps1` (Windows).

```bash
CLAUDE_NOTIFY_TOPIC="claude-notify-a1b2c3d4e5f6"
CLAUDE_NOTIFY_SERVER="https://ntfy.sh"
CLAUDE_NOTIFY_PRIORITY_PERMISSION="high"
CLAUDE_NOTIFY_PRIORITY_IDLE="high"
CLAUDE_NOTIFY_PRIORITY_DONE="default"
CLAUDE_NOTIFY_LOCAL="true"
```

## Manual Testing

```bash
# Test permission prompt notification
echo '{"type":"Notification","notification_type":"permission_prompt","message":"Claude wants to run: git push","title":"Permission Required"}' | bash hooks/notify.sh

# Test task completion
echo '{"type":"Stop","message":"Task completed successfully","title":"Claude Code"}' | bash hooks/notify.sh
```

## Uninstall

Remove the hook entries from `~/.claude/settings.json` and delete `~/.config/claude-notify/`.

## License

MIT

## Author

Chris Therriault <chris@servicevision.net> — 2026
