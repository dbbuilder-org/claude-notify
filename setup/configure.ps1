# claude-notify interactive configuration for Windows

$configDir = Join-Path $env:USERPROFILE ".config\claude-notify"
$configFile = Join-Path $configDir "config.ps1"

Write-Host "claude-notify configuration"
Write-Host "==========================="
Write-Host ""

# Generate topic
$bytes = New-Object byte[] 6
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$hex = ($bytes | ForEach-Object { $_.ToString("x2") }) -join ""
$defaultTopic = "claude-notify-$hex"

$topic = Read-Host "Enter ntfy topic [$defaultTopic]"
if (-not $topic) { $topic = $defaultTopic }

$server = Read-Host "Enter ntfy server [https://ntfy.sh]"
if (-not $server) { $server = "https://ntfy.sh" }

# Write config
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
Write-Host "Config saved to $configFile"
Write-Host ""

# Test
Write-Host "Sending test notification..."
try {
    Invoke-RestMethod -Uri "$server/$topic" -Method Post -Body "If you see this, notifications are working!" -Headers @{
        "Title"    = "claude-notify test"
        "Priority" = "default"
        "Tags"     = "test_tube"
    } -TimeoutSec 5 | Out-Null
    Write-Host "Test notification sent!" -ForegroundColor Green
} catch {
    Write-Host "Warning: could not send notification" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Subscribe in the ntfy app: $server/$topic"
Write-Host "Topic: $topic"
