# PC Monitoring Agent

A production-ready PowerShell background monitoring agent that sends heartbeat data to a remote API. Designed to run efficiently as a Windows Scheduled Task with minimal resource usage, offline queuing, and adaptive polling capabilities.

## Overview

The monitoring agent (`Agent.ps1`) runs every minute via Windows Task Scheduler as the SYSTEM account. It collects system information including hardware UUID, uptime, idle time, and user information, then sends it to a configured API endpoint. The agent includes advanced features such as:

- **Offline Queuing**: Stores failed requests locally and sends them when connectivity is restored
- **Adaptive Polling**: Reduces server load by skipping heartbeats when the system is idle
- **Hardware Identity**: Uses hardware UUID to identify devices even after renaming
- **Efficient Resource Usage**: Uses native .NET methods instead of WMI for better performance

## Installation

**For detailed installation instructions, see [INSTALL.md](INSTALL.md)**

### GUI Installation Wizard (Recommended)

The easiest way to install the monitoring agent is using the GUI installation wizard:

1. **Right-click** `Install-Wizard.bat` and select **"Run as administrator"**
   - This is the recommended method and handles all requirements automatically
   - **Note**: Do NOT use "Run with PowerShell" on the .ps1 file directly - it won't work without admin privileges
2. The installation wizard will open with a user-friendly interface
3. Enter your **API Endpoint URL** and **API Key**
4. The script path defaults to `C:\Program Files\MyAgent\Agent.ps1` (you can change this if needed)
5. Click **"Test Connection"** to verify your API credentials (optional but recommended)
6. Click **"Install"** to begin installation
7. The wizard will:
   - Create registry keys with your configuration
   - Create the necessary directories
   - Copy `Agent.ps1` to the specified location
   - Create and start the scheduled task
8. A success message will appear when installation is complete

**Requirements:**
- PowerShell 5.1 or higher
- Administrator privileges (the wizard will prompt if needed)
- `Agent.ps1` must be in the same directory as `Install-Wizard.ps1`

**Note:** The wizard will automatically copy `Agent.ps1` to the Program Files location, keeping it hidden from regular users.

### Manual Installation (Alternative Method)

If you prefer to install manually or need to script the installation, you can use the provisioning script below:

## Provisioning Script

Run this PowerShell script as Administrator to set up the monitoring agent:

```powershell
# Run as Administrator
#Requires -RunAsAdministrator

# Configuration - Update these values
$ApiUrl = "https://your-api-endpoint.com/api/heartbeat"
$ApiKey = "your-api-key-here"
$ScriptPath = "C:\Path\To\Agent.ps1"  # Update this to your script location
$TaskName = "MyPCMonitor"

# Create registry keys
$RegistryPath = "HKLM:\SOFTWARE\MyMonitoringAgent"
if (-not (Test-Path $RegistryPath)) {
    New-Item -Path $RegistryPath -Force | Out-Null
}
Set-ItemProperty -Path $RegistryPath -Name "ApiUrl" -Value $ApiUrl -Type String
Set-ItemProperty -Path $RegistryPath -Name "ApiKey" -Value $ApiKey -Type String

# Create data directory
$DataDirectory = "C:\ProgramData\MyAgent"
if (-not (Test-Path $DataDirectory)) {
    New-Item -ItemType Directory -Path $DataDirectory -Force | Out-Null
}

# Remove existing task if it exists
$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existingTask) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

# Create scheduled task action
$action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""

# Create scheduled task trigger (every 1 minute)
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 365)

# Create scheduled task principal (run as SYSTEM)
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

# Create scheduled task settings
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable:$false

# Register the scheduled task
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "PC Monitoring Agent - Sends heartbeat data to monitoring API" | Out-Null

# Start the task immediately
Start-ScheduledTask -TaskName $TaskName

Write-Host "Monitoring agent installed and started successfully!" -ForegroundColor Green
Write-Host "Task Name: $TaskName" -ForegroundColor Cyan
Write-Host "Runs: Every 1 minute" -ForegroundColor Cyan
Write-Host "Account: SYSTEM" -ForegroundColor Cyan
```

### Manual Provisioning Notes

- The script must be run as Administrator to create registry keys and scheduled tasks
- Update `$ApiUrl`, `$ApiKey`, and `$ScriptPath` variables before running
- The task will start immediately after installation
- The task is enabled by default and will automatically start on Windows boot
- The task runs every 1 minute continuously

**Recommended:** Use the GUI Installation Wizard instead for a simpler, error-free installation experience.

## Variable Reference Table

The following JSON payload is sent to the API endpoint on each heartbeat:

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `computerId` | string | Hardware UUID from Win32_ComputerSystemProduct. Unique identifier that persists even if computer is renamed. | `"550e8400-e29b-41d4-a716-446655440000"` |
| `computerName` | string | Current computer name from environment variable. | `"DESKTOP-ABC123"` |
| `username` | string | Current logged-in user. Extracted from Win32_ComputerSystem or environment. Domain prefix removed if present. | `"jsmith"` or `"Administrator"` |
| `online` | boolean | Always `true` when heartbeat is sent. | `true` |
| `pcStatus` | string | Always `"on"` when heartbeat is sent. | `"on"` |
| `pcUptime` | string | System uptime formatted as HH:mm:ss (if < 24h) or dd:hh:mm:ss (if ≥ 24h). Calculated from Environment.TickCount64 (native .NET, no WMI). | `"05:23:45"` or `"02:05:23:45"` |
| `idleTimeSeconds` | integer | Seconds since last user input. Uses Windows API GetLastInputInfo via C# P/Invoke. | `120` |
| `timestamp` | string | ISO 8601 UTC timestamp of when the heartbeat was generated. | `"2024-01-15T14:30:45.1234567Z"` |

### JSON Payload Example

```json
{
  "computerId": "550e8400-e29b-41d4-a716-446655440000",
  "computerName": "DESKTOP-ABC123",
  "username": "jsmith",
  "online": true,
  "pcStatus": "on",
  "pcUptime": "05:23:45",
  "idleTimeSeconds": 120,
  "timestamp": "2024-01-15T14:30:45.1234567Z"
}
```

## Safety Safeguards

The monitoring agent includes several safeguards to ensure reliable operation and efficient resource usage:

### Queue File Size Limit (10MB)

- Failed API requests are stored in `C:\ProgramData\MyAgent\queue.jsonl` (JSONL format - one JSON object per line)
- The queue file is automatically trimmed if it exceeds 10MB
- Oldest entries are deleted first, keeping the most recent data
- Prevents unbounded disk space usage during extended offline periods
- Queue is processed in batches of 50 items after a successful heartbeat

### Adaptive Polling

- When `idleTimeSeconds > 600` (10 minutes), the agent reduces polling frequency
- Heartbeats are skipped if less than 5 minutes have passed since the last successful send
- This reduces server load during idle periods while maintaining responsiveness
- When the user returns (idle time drops below threshold), normal polling resumes immediately
- Timestamp of last successful send is stored in `C:\ProgramData\MyAgent\last_send.txt`

### CPU Efficiency

- Uses native .NET `[Environment]::TickCount64` for uptime calculation instead of WMI queries
- Significantly faster and lower CPU overhead compared to WMI-based methods
- Idle time detection uses C# P/Invoke to call Windows API directly, avoiding PowerShell cmdlet overhead
- Minimal system resource usage designed for continuous background operation

### Error Logging

- All errors are logged to `C:\ProgramData\MyAgent\error.log` with timestamps
- Configuration errors (missing registry keys) are logged and the script exits gracefully
- API errors are logged but do not stop script execution (payloads are queued)
- Log format: `[YYYY-MM-DD HH:MM:SS] Error message`

### Network Resilience

- Failed API requests are automatically queued for retry
- Queue is processed after each successful heartbeat
- Allows the agent to continue operating during network outages
- Ensures no data loss during connectivity issues

## File Locations

| File/Directory | Purpose |
|----------------|---------|
| `Agent.ps1` | Main monitoring script (deploy to your preferred location) |
| `C:\ProgramData\MyAgent\` | Data directory (created automatically) |
| `C:\ProgramData\MyAgent\queue.jsonl` | Offline queue file (created when needed) |
| `C:\ProgramData\MyAgent\error.log` | Error log file (created when errors occur) |
| `C:\ProgramData\MyAgent\last_send.txt` | Last successful send timestamp (created when first heartbeat succeeds) |

## API Requirements

The API endpoint must:

- Accept POST requests with `Content-Type: application/json`
- Accept authentication via `X-API-KEY` HTTP header
- Accept the JSON payload schema as documented in the Variable Reference Table
- Return a valid HTTP response (2xx status codes indicate success)

## Troubleshooting

### Task Not Running

1. Verify the task exists: `Get-ScheduledTask -TaskName "MyPCMonitor"`
2. Check task status: `Get-ScheduledTaskInfo -TaskName "MyPCMonitor"`
3. Verify registry keys exist: `Get-ItemProperty "HKLM:\SOFTWARE\MyMonitoringAgent"`
4. Check error log: `Get-Content "C:\ProgramData\MyAgent\error.log"`

### No Data Received at API

1. Check error log for API connection errors
2. Verify `ApiUrl` and `ApiKey` in registry are correct
3. Check queue file for queued items: `Get-Content "C:\ProgramData\MyAgent\queue.jsonl"`
4. Verify network connectivity from the target machine

### High CPU Usage

- The agent is designed for minimal CPU usage
- If experiencing issues, verify only one instance of the task is running
- Check error log for repeated errors that might indicate a problem

## Security Considerations

- The agent runs as SYSTEM account - ensure script integrity
- API key is stored in registry (HKLM) - protect registry access
- Data directory uses standard ProgramData location with appropriate permissions
- No sensitive user data is transmitted (only username, no passwords or tokens)

