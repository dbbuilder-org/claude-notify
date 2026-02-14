# Claude Code Hooks — Beyond Notifications

A guide to everything you can do with Claude Code hooks, plus an architecture for **remote control** — clicking a notification on your phone to tell Claude to proceed.

---

## Table of Contents

1. [Hook Events Reference](#hook-events-reference)
2. [Practical Hook Recipes](#practical-hook-recipes)
3. [Remote Control Architecture](#remote-control-architecture)
4. [Implementation Plan: claude-notify-server](#implementation-plan-claude-notify-server)

---

## Hook Events Reference

Claude Code exposes 14 lifecycle events. Each receives JSON on stdin and can respond via exit codes and JSON on stdout.

| Event | Fires when... | Can block? | Matcher |
|-------|---------------|------------|---------|
| `SessionStart` | Session begins/resumes | No | `startup`, `resume`, `clear`, `compact` |
| `UserPromptSubmit` | User sends a prompt | Yes | — |
| `PreToolUse` | Before a tool runs | Yes | Tool names (`Bash`, `Write`, `mcp__*`) |
| `PermissionRequest` | Permission dialog shown | Yes | Tool names |
| `PostToolUse` | After tool succeeds | No | Tool names |
| `PostToolUseFailure` | After tool fails | No | Tool names |
| `PreCompact` | Before context compaction | No | `manual`, `auto` |
| `Notification` | Notification dispatched | No | `permission_prompt`, `idle_prompt`, `elicitation_dialog` |
| `SubagentStart` | Subagent spawned | No | Agent type (`Bash`, `Explore`, `Plan`) |
| `SubagentStop` | Subagent finishes | Yes | Agent type |
| `Stop` | Claude finishes responding | Yes | — |
| `TeammateIdle` | Teammate going idle | Yes | — |
| `TaskCompleted` | Task marked done | Yes | — |
| `SessionEnd` | Session terminates | No | `clear`, `logout`, `prompt_input_exit`, `other` |

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success — action proceeds, stdout JSON parsed for decisions |
| `2` | Block — action prevented, stderr fed to Claude as reason |
| Other | Non-blocking error — ignored, execution continues |

### Common JSON Payload (all events)

```json
{
  "session_id": "abc123",
  "transcript_path": "/Users/you/.claude/projects/.../transcript.jsonl",
  "cwd": "/Users/you/dev2/my-project",
  "permission_mode": "default",
  "hook_event_name": "PreToolUse"
}
```

---

## Practical Hook Recipes

### 1. Auto-format files after edits

Run Prettier on any file Claude writes or edits.

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [{
          "type": "command",
          "command": "bash -c \"jq -r '.tool_input.file_path' | xargs npx prettier --write 2>/dev/null\"",
          "timeout": 15
        }]
      }
    ]
  }
}
```

### 2. Block destructive commands

Prevent `rm -rf`, `git push --force`, etc.

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{
          "type": "command",
          "command": "bash ~/.claude/hooks/block-destructive.sh",
          "timeout": 5
        }]
      }
    ]
  }
}
```

`block-destructive.sh`:
```bash
#!/usr/bin/env bash
INPUT="$(cat)"
CMD="$(echo "$INPUT" | jq -r '.tool_input.command // empty')"

BLOCKED_PATTERNS=(
  "rm -rf /"
  "git push.*--force.*main"
  "git reset --hard"
  "DROP TABLE"
  "DROP DATABASE"
)

for pattern in "${BLOCKED_PATTERNS[@]}"; do
  if echo "$CMD" | grep -qiE "$pattern"; then
    echo "Blocked: matches pattern '$pattern'" >&2
    exit 2
  fi
done

exit 0
```

### 3. Run tests before Claude stops

Force Claude to verify tests pass before finishing.

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [{
          "type": "agent",
          "prompt": "Before finishing, run the test suite with 'npm test'. If any tests fail, fix them. $ARGUMENTS",
          "model": "sonnet",
          "timeout": 120
        }]
      }
    ]
  }
}
```

### 4. Log all tool usage

Append every tool invocation to a log file for auditing.

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [{
          "type": "command",
          "command": "bash -c \"cat >> ~/.claude/tool-audit.jsonl\"",
          "timeout": 5
        }]
      }
    ]
  }
}
```

### 5. Inject context on session start

Load project-specific context automatically.

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup",
        "hooks": [{
          "type": "command",
          "command": "bash ~/.claude/hooks/inject-context.sh",
          "timeout": 10
        }]
      }
    ]
  }
}
```

`inject-context.sh`:
```bash
#!/usr/bin/env bash
INPUT="$(cat)"
CWD="$(echo "$INPUT" | jq -r '.cwd')"

# Persist env vars for all Bash commands in this session
if [[ -n "${CLAUDE_ENV_FILE:-}" ]]; then
  echo "export PROJECT_ROOT=\"$CWD\"" >> "$CLAUDE_ENV_FILE"
fi

# Inject additional context into Claude's conversation
jq -n --arg ctx "Current git branch: $(git -C "$CWD" branch --show-current 2>/dev/null || echo 'unknown')" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $ctx
  }
}'
```

### 6. Auto-approve safe tools

Let Claude run `Read`, `Glob`, `Grep` without permission prompts.

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Read|Glob|Grep",
        "hooks": [{
          "type": "command",
          "command": "bash -c \"jq -n '{hookSpecificOutput:{hookEventName:\\\"PreToolUse\\\",permissionDecision:\\\"allow\\\"}}'\"",
          "timeout": 5
        }]
      }
    ]
  }
}
```

### 7. Rewrite commands (sandboxing)

Prefix all Bash commands with a custom wrapper.

```bash
#!/usr/bin/env bash
# hooks/sandbox-bash.sh — rewrites Bash tool input
INPUT="$(cat)"
CMD="$(echo "$INPUT" | jq -r '.tool_input.command')"

# Example: force all npm commands to use --ignore-scripts
if echo "$CMD" | grep -q "^npm install"; then
  SAFE_CMD="$CMD --ignore-scripts"
  jq -n --arg cmd "$SAFE_CMD" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      updatedInput: { command: $cmd }
    }
  }'
else
  exit 0
fi
```

### 8. Track session time

Log start/end times per project.

```json
{
  "hooks": {
    "SessionStart": [{
      "matcher": "startup",
      "hooks": [{
        "type": "command",
        "command": "bash -c \"echo \\\"$(date -u +%Y-%m-%dT%H:%M:%SZ) START $(jq -r '.cwd')\\\" >> ~/.claude/session-time.log\"",
        "timeout": 5
      }]
    }],
    "SessionEnd": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "bash -c \"echo \\\"$(date -u +%Y-%m-%dT%H:%M:%SZ) END $(jq -r '.cwd')\\\" >> ~/.claude/session-time.log\"",
        "timeout": 5
      }]
    }]
  }
}
```

---

## Remote Control Architecture

**The idea:** When Claude Code sends a notification to your phone, the notification includes a clickable URL. Tapping it either:

1. **Approve** — sends `y` + Enter to the waiting Claude Code prompt
2. **Deny** — sends `n` + Enter
3. **Custom** — opens a one-time web page where you type a command, which gets sent to Claude

### How It Works

```
┌──────────────┐     stdin JSON      ┌──────────────────┐
│  Claude Code │ ──────────────────▶ │  notify.sh hook  │
│  (iTerm2)    │                     │                  │
└──────┬───────┘                     └────────┬─────────┘
       │                                      │
       │                              ┌───────▼──────────┐
       │                              │  claude-notify   │
       │                              │  server (local)  │
       │                              │  :9876            │
       │                              │                  │
       │                              │  Registers:      │
       │                              │  UUID → {        │
       │                              │   session_id,    │
       │                              │   iterm_session, │
       │                              │   action_type,   │
       │                              │   one_time: true │
       │                              │  }               │
       │                              └───────┬──────────┘
       │                                      │
       │                              ┌───────▼──────────┐
       │                              │  ntfy.sh         │
       │                              │                  │
       │                              │  Click URL:      │
       │                              │  http://mac:9876 │
       │                              │  /action/{uuid}  │
       │                              │                  │
       │                              │  Action buttons: │
       │                              │  [Approve] [Deny]│
       │                              └───────┬──────────┘
       │                                      │
       │                              ┌───────▼──────────┐
       │                              │  User's phone    │
       │                              │  taps "Approve"  │
       │                              └───────┬──────────┘
       │                                      │
       │    ┌─────────────────────────────────▼┐
       │    │  Tailscale / Cloudflare Tunnel   │
       │    │  routes to mac:9876              │
       │    └─────────────────────────────┬────┘
       │                                  │
       │                          ┌───────▼──────────┐
       │                          │  claude-notify   │
       │                          │  server receives │
       │                          │  GET /action/uuid│
       │                          │                  │
       │                          │  Looks up UUID   │
       │                          │  Invalidates it  │
       │                          │  (one-time use)  │
       │                          └───────┬──────────┘
       │                                  │
       │           osascript              │
       ◀──────────────────────────────────┘
       │  tell application "iTerm2"
       │    tell session id "xxx"
       │      write text "y"
       │    end tell
       │  end tell
       │
  Claude proceeds
```

### Key Components

#### 1. Session Registration (SessionStart hook)

When Claude Code starts, capture the iTerm2 session ID and register it with the server.

```bash
#!/usr/bin/env bash
# hooks/register-session.sh
INPUT="$(cat)"
SESSION_ID="$(echo "$INPUT" | jq -r '.session_id')"

# iTerm2 sets this env var in each pane
ITERM_SESSION="${ITERM_SESSION_ID:-}"

# Register with local server
curl -s -m 2 -X POST http://localhost:9876/session \
  -H "Content-Type: application/json" \
  -d "{
    \"session_id\": \"$SESSION_ID\",
    \"iterm_session\": \"$ITERM_SESSION\",
    \"cwd\": \"$(echo "$INPUT" | jq -r '.cwd')\"
  }" >/dev/null 2>&1 || true

exit 0
```

#### 2. Notification with Action URL (updated notify.sh)

When sending a notification, also register a one-time action token with the server.

```bash
# Generate one-time action UUID
ACTION_UUID="$(uuidgen | tr '[:upper:]' '[:lower:]')"

# Register with server
curl -s -m 2 -X POST http://localhost:9876/register-action \
  -H "Content-Type: application/json" \
  -d "{
    \"uuid\": \"$ACTION_UUID\",
    \"session_id\": \"$SESSION_ID\",
    \"notification_type\": \"$NOTIFICATION_TYPE\",
    \"message\": \"$MESSAGE\"
  }" >/dev/null 2>&1 || true

# Server base URL (accessible from phone — Tailscale, Cloudflare Tunnel, etc.)
SERVER_URL="${CLAUDE_NOTIFY_REMOTE_URL:-http://localhost:9876}"

# Send to ntfy with action buttons
curl -s -m 5 \
  -H "Title: ${TITLE}" \
  -H "Priority: ${PRIORITY}" \
  -H "Tags: ${TAGS}" \
  -H "Click: ${SERVER_URL}/action/${ACTION_UUID}" \
  -H "Actions: view, Approve, ${SERVER_URL}/approve/${ACTION_UUID}, clear=true; view, Open, ${SERVER_URL}/control/${ACTION_UUID}" \
  -d "${MESSAGE}" \
  "${CLAUDE_NOTIFY_SERVER}/${CLAUDE_NOTIFY_TOPIC}" >/dev/null 2>&1
```

This gives the notification **two action buttons**:
- **Approve** — one-tap: sends `y` to Claude immediately
- **Open** — opens a web page with a text field for custom input

#### 3. Local REST Server (`claude-notify-server`)

A lightweight Node.js (or Deno/Bun) server running on the Mac.

**Endpoints:**

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/session` | Register a Claude Code session + iTerm2 session mapping |
| `POST` | `/register-action` | Create a one-time action token |
| `GET` | `/approve/{uuid}` | Send "y" to the mapped iTerm2 session, invalidate token |
| `GET` | `/deny/{uuid}` | Send "n" to the mapped iTerm2 session, invalidate token |
| `GET` | `/control/{uuid}` | Serve a simple web page with a text input |
| `POST` | `/control/{uuid}` | Send custom text to the mapped iTerm2 session, invalidate token |

**Data model (in-memory, no database):**

```
sessions: Map<claude_session_id, {
  iterm_session: string,
  cwd: string,
  registered_at: Date
}>

actions: Map<uuid, {
  session_id: string,
  notification_type: string,
  message: string,
  created_at: Date,
  used: boolean           // one-time use flag
}>
```

Actions expire after 30 minutes and are invalidated after first use.

#### 4. iTerm2 Keystroke Injection

The server sends keystrokes to the correct iTerm2 pane via AppleScript:

```bash
# Send "y" + Enter to a specific iTerm2 session
osascript -e '
  tell application "iTerm2"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if unique ID of s is "'"$ITERM_SESSION_ID"'" then
            tell s to write text "y"
            return
          end if
        end repeat
      end repeat
    end repeat
  end tell
'
```

For custom input from the web page:

```bash
osascript -e '
  tell application "iTerm2"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if unique ID of s is "'"$ITERM_SESSION_ID"'" then
            tell s to write text "'"$USER_INPUT"'"
            return
          end if
        end repeat
      end repeat
    end repeat
  end tell
'
```

#### 5. Control Web Page

A minimal HTML page served at `/control/{uuid}`:

```
┌─────────────────────────────────┐
│  Claude Code Remote Control     │
│                                 │
│  Project: FaithVision           │
│  Event: Permission Required     │
│  Message: Claude wants to run:  │
│           git push origin main  │
│                                 │
│  ┌───────────────────────────┐  │
│  │ Type a response...        │  │
│  └───────────────────────────┘  │
│                                 │
│  [Approve]  [Deny]  [Send]      │
│                                 │
│  ⚠ This link expires in 28m    │
│  ⚠ One-time use only           │
└─────────────────────────────────┘
```

After submitting, the page shows "Sent!" and the token is invalidated.

### Network Access

The server runs on `localhost:9876`. To reach it from your phone, you need one of:

| Method | Setup | Security |
|--------|-------|----------|
| **Tailscale** (recommended) | Install on Mac + phone, access via `http://mac-hostname:9876` | WireGuard encrypted, private |
| **Cloudflare Tunnel** | `cloudflared tunnel --url http://localhost:9876` | Public URL but authed via Cloudflare Access |
| **ngrok** | `ngrok http 9876` | Public URL, token-based |
| **SSH tunnel** | `ssh -R 9876:localhost:9876 your-vps` | Manual, reliable |
| **Local only** | Same Wi-Fi network, use Mac's IP | No encryption, LAN only |

Tailscale is the simplest — install on Mac and phone, everything just works over your private network.

### Security Considerations

| Concern | Mitigation |
|---------|------------|
| Token guessing | UUIDs are 128-bit random — unguessable |
| Token reuse | One-time use, invalidated after first use |
| Token expiry | Auto-expire after 30 minutes |
| Network sniffing | Use Tailscale (encrypted) or HTTPS tunnel |
| Unauthorized access | Server only listens on localhost; tunnel handles auth |
| Command injection | Sanitize user input before passing to osascript |
| Session hijacking | Tokens bound to specific session_id |

---

## Implementation Plan: claude-notify-server

### Phase 1: Core Server

Add to the claude-notify project:

```
claude-notify/
├── server/
│   ├── index.ts              # Bun/Deno HTTP server
│   ├── store.ts              # In-memory session + action store
│   ├── iterm.ts              # iTerm2 AppleScript integration
│   ├── pages/
│   │   └── control.html      # Remote control web page
│   └── package.json
```

**Stack choice:** Bun or Deno — single binary, TypeScript, zero deps, fast startup. Runs as a launchd service on macOS.

### Phase 2: Hook Integration

Update existing hooks:

1. **SessionStart hook** — registers iTerm2 session ID with server
2. **notify.sh** — registers action tokens and includes click URLs + action buttons in ntfy notifications
3. **SessionEnd hook** — cleans up session from server

### Phase 3: launchd Service

Auto-start the server on macOS:

```xml
<!-- ~/Library/LaunchAgents/com.claude-notify.server.plist -->
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.claude-notify.server</string>
  <key>ProgramArguments</key>
  <array>
    <string>/path/to/bun</string>
    <string>run</string>
    <string>/Users/you/dev2/claude-notify/server/index.ts</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
</dict>
</plist>
```

### Phase 4: Windows Support

- Replace osascript with Windows Terminal / PowerShell remoting
- Replace launchd with Windows Task Scheduler
- Same server, same API

---

## Summary

| Layer | What | Status |
|-------|------|--------|
| Notifications | ntfy.sh push + local fallback | **Done** (claude-notify) |
| Hook recipes | Format, block, log, inject context | Documented above |
| Remote control server | REST API + iTerm2 keystroke injection | **Design complete** |
| Action buttons | Approve/Deny/Custom from phone | **Design complete** |
| Network access | Tailscale / Cloudflare Tunnel | Choose one |

The notification layer is working today. The remote control layer is the next step — a lightweight server that turns ntfy notifications into two-way communication with Claude Code.

---

*Chris Therriault <chris@servicevision.net> — 2026*
