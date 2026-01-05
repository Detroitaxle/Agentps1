# Show exact payload format that would be sent
$IdleTimeSeconds = 900  # 15 minutes idle

# Example values (these would be real values from your PC)
$computerId = "20E47205-844A-11EA-80DC-002B6735BC59"  # Hardware UUID
$computerName = "SAM"  # Your PC name
$username = "samsa"  # Current user
$uptimeFormatted = "02:05:30:15"  # Format: DD:HH:MM:SS (2 days, 5 hours, 30 minutes, 15 seconds)
$timestamp = (Get-Date).ToUniversalTime().ToString("o")  # ISO 8601 format

# Build payload (same format as Agent.ps1)
$payload = @{
    computerId = $computerId
    computerName = $computerName
    username = $username
    online = $true
    pcStatus = "on"
    pcUptime = $uptimeFormatted
    idleTimeSeconds = $IdleTimeSeconds
    timestamp = $timestamp
}

Write-Host "=== PAYLOAD STRUCTURE ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Compressed JSON (what gets sent over HTTP):" -ForegroundColor Yellow
$compressed = $payload | ConvertTo-Json -Compress
Write-Host $compressed -ForegroundColor White
Write-Host ""

Write-Host "Formatted JSON (for readability):" -ForegroundColor Yellow
$payload | ConvertTo-Json -Depth 10 | Write-Host -ForegroundColor White
Write-Host ""

Write-Host "=== FIELD DESCRIPTIONS ===" -ForegroundColor Cyan
Write-Host "computerId:      $($payload.computerId) (Hardware UUID - unique per PC)" -ForegroundColor Gray
Write-Host "computerName:    $($payload.computerName) (Windows computer name)" -ForegroundColor Gray
Write-Host "username:        $($payload.username) (Current logged-in user)" -ForegroundColor Gray
Write-Host "online:          $($payload.online) (Always true for heartbeat)" -ForegroundColor Gray
Write-Host "pcStatus:        $($payload.pcStatus) (Always 'on' for heartbeat)" -ForegroundColor Gray
Write-Host "pcUptime:        $($payload.pcUptime) (Format: DD:HH:MM:SS)" -ForegroundColor Gray
Write-Host "idleTimeSeconds: $($payload.idleTimeSeconds) (Seconds since last user input)" -ForegroundColor Gray
Write-Host "timestamp:       $($payload.timestamp) (ISO 8601 UTC timestamp)" -ForegroundColor Gray
Write-Host ""

Write-Host "=== HTTP HEADERS ===" -ForegroundColor Cyan
Write-Host "Content-Type: application/json" -ForegroundColor Gray
Write-Host "X-API-KEY: <your-api-key>" -ForegroundColor Gray
Write-Host ""

Write-Host "Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

