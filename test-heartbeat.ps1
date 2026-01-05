# Test Heartbeat Script - Send fake data to API
# Usage: .\test-heartbeat.ps1 -ApiUrl "https://workpulse.replit.app/api/heartbeat" -ApiKey "your-key" -IdleTimeSeconds 600

param(
    [Parameter(Mandatory=$false)]
    [string]$ApiUrl = "https://workpulse.replit.app/api/heartbeat",
    
    [Parameter(Mandatory=$false)]
    [string]$ApiKey = "f47ac10b-58cc-4372-a567-0e02b2c3d479",
    
    [Parameter(Mandatory=$false)]
    [int]$IdleTimeSeconds = 0,
    
    [Parameter(Mandatory=$false)]
    [string]$ComputerName = $null,
    
    [Parameter(Mandatory=$false)]
    [string]$Username = $null
)

Write-Host "=== Test Heartbeat Sender ===" -ForegroundColor Cyan
Write-Host ""

# Get real values or use provided/test values
$computerId = if ($ComputerName) { 
    "TEST-$ComputerName" 
} else { 
    try {
        (Get-CimInstance -ClassName Win32_ComputerSystemProduct).UUID
    } catch {
        "TEST-COMPUTER-" + (New-Guid).ToString().Substring(0,8)
    }
}

$computerName = if ($ComputerName) { 
    $ComputerName 
} else { 
    if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { "TEST-PC" }
}

$username = if ($Username) { 
    $Username 
} else { 
    try {
        $u = (Get-CimInstance Win32_ComputerSystem).UserName
        if ($u -match '\\') { $u.Split('\')[-1] } else { $u }
    } catch {
        if ($env:USERNAME) { $env:USERNAME } else { "TEST-USER" }
    }
}

# Calculate fake uptime (or use real)
$uptimeDays = 2
$uptimeHours = 5
$uptimeMinutes = 30
$uptimeSeconds = 15
$uptimeFormatted = "{0:00}:{1:00}:{2:00}:{3:00}" -f $uptimeDays, $uptimeHours, $uptimeMinutes, $uptimeSeconds
$uptimeTotalSeconds = ($uptimeDays * 86400) + ($uptimeHours * 3600) + ($uptimeMinutes * 60) + $uptimeSeconds

# Build payload
$payload = @{
    computerId = $computerId
    computerName = $computerName
    username = $username
    online = $true
    pcStatus = "on"
    pcUptime = $uptimeFormatted
    idleTimeSeconds = $IdleTimeSeconds
    timestamp = (Get-Date).ToUniversalTime().ToString("o")
} | ConvertTo-Json -Compress

Write-Host "Sending test heartbeat with:" -ForegroundColor Yellow
Write-Host "  Computer ID: $computerId" -ForegroundColor Gray
Write-Host "  Computer Name: $computerName" -ForegroundColor Gray
Write-Host "  Username: $username" -ForegroundColor Gray
Write-Host "  Uptime: $uptimeFormatted ($uptimeTotalSeconds seconds)" -ForegroundColor Gray
Write-Host "  Idle Time: $IdleTimeSeconds seconds" -ForegroundColor $(if ($IdleTimeSeconds -gt 600) { "Red" } else { "Green" })
Write-Host "  Timestamp: $((Get-Date).ToUniversalTime().ToString('o'))" -ForegroundColor Gray
Write-Host ""

$headers = @{
    "Content-Type" = "application/json"
    "X-API-KEY" = $ApiKey
}

Write-Host "Payload JSON:" -ForegroundColor Cyan
Write-Host $payload -ForegroundColor Gray
Write-Host ""

try {
    Write-Host "Sending POST request..." -ForegroundColor Yellow
    $response = Invoke-RestMethod -Uri $ApiUrl -Method Post -Headers $headers -Body $payload -ContentType "application/json" -TimeoutSec 10 -ErrorAction Stop
    
    Write-Host ""
    Write-Host "SUCCESS! Response received:" -ForegroundColor Green
    Write-Host ($response | ConvertTo-Json -Depth 10) -ForegroundColor Green
    Write-Host ""
    Write-Host "Heartbeat sent successfully!" -ForegroundColor Green
} catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    
    if ($_.Exception.Response) {
        try {
            $statusCode = $_.Exception.Response.StatusCode.value__
            Write-Host "HTTP Status Code: $statusCode" -ForegroundColor Yellow
            
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $responseBody = $reader.ReadToEnd()
            $reader.Close()
            Write-Host "Response Body: $responseBody" -ForegroundColor Yellow
        } catch {
            Write-Host "Could not read response body" -ForegroundColor Yellow
        }
    }
    exit 1
}

Write-Host ""
Write-Host "Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

