# claude-notify installer for Windows
# Configures Claude Code hooks to send push notifications via ntfy.sh

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configDir = Join-Path $env:USERPROFILE ".config\claude-notify"
$configFile = Join-Path $configDir "config.ps1"
$claudeSettings = Join-Path $env:USERPROFILE ".claude\settings.json"
$hookDir = Join-Path $scriptDir "hooks"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  claude-notify installer" -ForegroundColor Cyan
Write-Host "  Push notifications for Claude Code" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# --- Generate or load topic ---
$topic = $null
$server = "https://ntfy.sh"

if (Test-Path $configFile) {
    . $configFile
    $topic = $env:CLAUDE_NOTIFY_TOPIC
    $server = if ($env:CLAUDE_NOTIFY_SERVER) { $env:CLAUDE_NOTIFY_SERVER } else { "https://ntfy.sh" }
    Write-Host "Existing config found: topic = $topic"
    $keep = Read-Host "Keep existing config? [Y/n]"
    if ($keep -eq "n") { $topic = $null }
}

if (-not $topic) {
    $bytes = New-Object byte[] 6
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $hex = ($bytes | ForEach-Object { $_.ToString("x2") }) -join ""
    $generatedTopic = "claude-notify-$hex"

    Write-Host ""
    Write-Host "Generated topic: $generatedTopic"
    $customTopic = Read-Host "Use this topic? (or type a custom one) [$generatedTopic]"
    $topic = if ($customTopic) { $customTopic } else { $generatedTopic }
}

# --- Write config ---
New-Item -ItemType Directory -Path $configDir -Force | Out-Null

@"
`$env:CLAUDE_NOTIFY_TOPIC = "$topic"
`$env:CLAUDE_NOTIFY_SERVER = "$server"
`$env:CLAUDE_NOTIFY_PRIORITY_PERMISSION = "high"
`$env:CLAUDE_NOTIFY_PRIORITY_IDLE = "high"
`$env:CLAUDE_NOTIFY_PRIORITY_DONE = "default"
`$env:CLAUDE_NOTIFY_LOCAL = "true"
"@ | Set-Content $configFile -Encoding UTF8

Write-Host ""
Write-Host "Config written to: $configFile"

# --- Configure Claude Code hooks ---
Write-Host ""
Write-Host "Configuring Claude Code hooks..."

$claudeDir = Split-Path $claudeSettings
if (-not (Test-Path $claudeDir)) {
    New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
}

$notifyScript = Join-Path $hookDir "notify.ps1"

# Load or create settings
$settings = if (Test-Path $claudeSettings) {
    Get-Content $claudeSettings -Raw | ConvertFrom-Json
} else {
    [PSCustomObject]@{}
}

# Ensure hooks object exists
if (-not $settings.hooks) {
    $settings | Add-Member -NotePropertyName "hooks" -NotePropertyValue ([PSCustomObject]@{})
}

$hookCmd = "powershell -ExecutionPolicy Bypass -File `"$notifyScript`""

$hookEntry = [PSCustomObject]@{
    type    = "command"
    command = $hookCmd
    timeout = 10
}

# Build Notification hooks (with matchers)
$notificationHooks = @(
    [PSCustomObject]@{ matcher = "permission_prompt"; hooks = @($hookEntry) },
    [PSCustomObject]@{ matcher = "idle_prompt"; hooks = @($hookEntry) },
    [PSCustomObject]@{ matcher = "elicitation_dialog"; hooks = @($hookEntry) }
)

# Build Stop hooks (no matcher)
$stopHooks = @(
    [PSCustomObject]@{ hooks = @($hookEntry) }
)

# Remove existing claude-notify entries and add ours
$existingNotification = @()
if ($settings.hooks.Notification) {
    $existingNotification = @($settings.hooks.Notification | Where-Object {
        -not ($_.hooks | Where-Object { $_.command -like "*claude-notify*" })
    })
}
$existingStop = @()
if ($settings.hooks.Stop) {
    $existingStop = @($settings.hooks.Stop | Where-Object {
        -not ($_.hooks | Where-Object { $_.command -like "*claude-notify*" })
    })
}

$settings.hooks | Add-Member -NotePropertyName "Notification" -NotePropertyValue ($existingNotification + $notificationHooks) -Force
$settings.hooks | Add-Member -NotePropertyName "Stop" -NotePropertyValue ($existingStop + $stopHooks) -Force

$settings | ConvertTo-Json -Depth 10 | Set-Content $claudeSettings -Encoding UTF8
Write-Host "Hooks added to: $claudeSettings"

# --- Send test notification ---
Write-Host ""
Write-Host "Sending test notification..."

try {
    $url = "$server/$topic"
    $headers = @{
        "Title"    = "claude-notify installed!"
        "Priority" = "default"
        "Tags"     = "white_check_mark,tada"
    }
    Invoke-RestMethod -Uri $url -Method Post -Body "Notifications are working. You'll be notified when Claude Code needs attention." -Headers $headers -TimeoutSec 5 | Out-Null
    Write-Host "Test notification sent!" -ForegroundColor Green
} catch {
    Write-Host "Warning: Could not send test notification. Check your network." -ForegroundColor Yellow
}

# Local notification test
if ($env:CLAUDE_NOTIFY_LOCAL -eq "true") {
    try {
        if (Get-Module -ListAvailable -Name BurntToast) {
            Import-Module BurntToast
            New-BurntToastNotification -Text "claude-notify installed!", "Local notifications are working too."
        }
    } catch {}
}

# --- Print subscription info ---
$topicUrl = "$server/$topic"
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Setup complete!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Subscribe to notifications on your phone:"
Write-Host ""
Write-Host "  1. Install the ntfy app (iOS/Android)"
Write-Host "  2. Subscribe to this topic:"
Write-Host ""
Write-Host "     $topicUrl" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Topic: $topic" -ForegroundColor Yellow
Write-Host ""
Write-Host "Restart Claude Code for hooks to take effect."
Write-Host ""
