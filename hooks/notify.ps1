# claude-notify hook script for Windows
# Called by Claude Code hooks — reads event JSON from stdin, sends push notification via ntfy.sh

$ErrorActionPreference = "SilentlyContinue"

# Load config
$configFile = Join-Path $env:USERPROFILE ".config\claude-notify\config.ps1"
if (Test-Path $configFile) {
    . $configFile
} else {
    Write-Error "claude-notify: config not found at $configFile"
    exit 0  # Don't block Claude Code
}

# Defaults
if (-not $env:CLAUDE_NOTIFY_SERVER) { $env:CLAUDE_NOTIFY_SERVER = "https://ntfy.sh" }
if (-not $env:CLAUDE_NOTIFY_LOCAL) { $env:CLAUDE_NOTIFY_LOCAL = "true" }

# Read JSON from stdin
$input = $null
try {
    $inputRaw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($inputRaw)) { exit 0 }
    $inputObj = $inputRaw | ConvertFrom-Json
} catch {
    exit 0
}

# Parse event fields
$eventType = $inputObj.type
$notificationType = $inputObj.notification_type
$message = if ($inputObj.message) { $inputObj.message } else { "Claude Code needs your attention" }
$title = if ($inputObj.title) { $inputObj.title } else { "Claude Code" }

# Resolve project name from JSON cwd field, env var, or fallback
$projectDir = if ($inputObj.cwd) { $inputObj.cwd } elseif ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { "" }
$projectName = if ($projectDir) { Split-Path $projectDir -Leaf } else { "" }

# Map notification type to priority and emoji tag
$priority = "default"
$tags = "computer"

switch ($eventType) {
    "Notification" {
        switch ($notificationType) {
            "permission_prompt" {
                $priority = if ($env:CLAUDE_NOTIFY_PRIORITY_PERMISSION) { $env:CLAUDE_NOTIFY_PRIORITY_PERMISSION } else { "high" }
                $tags = "lock"
                $title = "Permission Required"
            }
            "idle_prompt" {
                $priority = if ($env:CLAUDE_NOTIFY_PRIORITY_IDLE) { $env:CLAUDE_NOTIFY_PRIORITY_IDLE } else { "high" }
                $tags = "hourglass"
                $title = "Claude Code is Idle"
            }
            "elicitation_dialog" {
                $priority = "default"
                $tags = "question"
                $title = "Claude Code has a Question"
            }
            default {
                $priority = "default"
                $tags = "bell"
            }
        }
    }
    "Stop" {
        $priority = if ($env:CLAUDE_NOTIFY_PRIORITY_DONE) { $env:CLAUDE_NOTIFY_PRIORITY_DONE } else { "default" }
        $tags = "white_check_mark"
        $title = "Task Complete"
    }
    default {
        $priority = "default"
        $tags = "bell"
    }
}

# Prepend project name to title
if ($projectName) {
    $title = "[$projectName] $title"
}

# Truncate message
if ($message.Length -gt 200) {
    $message = $message.Substring(0, 197) + "..."
}

# Send to ntfy.sh
if ($env:CLAUDE_NOTIFY_TOPIC) {
    $url = "$($env:CLAUDE_NOTIFY_SERVER)/$($env:CLAUDE_NOTIFY_TOPIC)"
    $headers = @{
        "Title"    = $title
        "Priority" = $priority
        "Tags"     = $tags
    }
    try {
        Invoke-RestMethod -Uri $url -Method Post -Body $message -Headers $headers -TimeoutSec 5 | Out-Null
    } catch {
        # Silently fail — don't block Claude Code
    }
}

# Local notification via BurntToast (if available and enabled)
if ($env:CLAUDE_NOTIFY_LOCAL -eq "true") {
    try {
        if (Get-Module -ListAvailable -Name BurntToast) {
            Import-Module BurntToast -ErrorAction SilentlyContinue
            New-BurntToastNotification -Text $title, $message -ErrorAction SilentlyContinue
        }
    } catch {
        # Silently fail
    }
}

exit 0
