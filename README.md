# PC Monitoring Agent

A simple PowerShell agent that sends system heartbeat data to your API every minute. Runs in the background, collects basic system info, and handles offline periods gracefully.

## What It Does

Every minute, the agent collects:
- Computer hardware ID (persistent UUID)
- Computer name
- Logged-in username
- System uptime
- Idle time (seconds since last keyboard/mouse input)
- Current timestamp

Then sends it to your API endpoint as JSON.

## Features

**Offline Queue** - If the API is down, heartbeats are saved locally and sent automatically when connection is restored. Queue processes 100 items at a time and auto-trims at 10MB.

**Adaptive Polling** - When the computer is idle for more than 10 minutes, reduces polling from every 1 minute to every 5 minutes to reduce server load.

**Hardware ID** - Uses motherboard UUID that stays the same even after OS reinstall or drive replacement.

## Installation

### GUI Installer (Recommended)

1. Right-click `Install-Wizard.bat` → "Run as administrator"
2. Enter your API endpoint URL (must be HTTP or HTTPS)
3. Enter your API key
4. Click "Install"

Creates a scheduled task named "MyPCMonitor" that runs every minute.

### Silent Installer

For automated deployments:

```powershell
.\Install-Silent.ps1 -ApiUrl "https://your-api.com/api/heartbeat" -ApiKey "your-key-here"
```

Run as administrator.

## Configuration

Settings are stored in Windows Registry:
- Location: `HKLM:\SOFTWARE\MyMonitoringAgent`
- Keys: `ApiUrl`, `ApiKey`

Data files are in `C:\ProgramData\MyAgent\`:
- `queue.jsonl` - Failed requests waiting to be sent
- `error.log` - Error messages
- `last_send.txt` - Timestamp of last successful send

## Data Format

Each heartbeat sends this JSON:

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

## API Requirements

Your endpoint must:
- Accept POST requests
- Accept `application/json` content type
- Accept API key via `X-API-KEY` header
- Return HTTP 2xx (200, 201, etc.) for success

## Management

**Check Status:**
```powershell
.\check-agent-status.ps1
```

Shows task status, config, queue, errors, and current system state.

**Update Agent:**
```powershell
.\update-agent.bat
```

Run as administrator. Copies new `Agent.ps1` to install location and updates the task.

**Uninstall:**
```powershell
.\uninstall.bat
```

Run as administrator. Removes task, registry keys, and script files. Data directory is kept by default.

## How It Works

Runs as a Windows Scheduled Task ("MyPCMonitor") that executes every minute. The task runs as the current user account (not SYSTEM). Each run:

1. Loads API URL and key from registry
2. Checks idle time (if idle > 10 min and last send < 5 min ago, skips this heartbeat)
3. Collects system info
4. Sends to API (or queues if it fails)
5. Processes queued items if send succeeded

## Troubleshooting

**Agent not running?**
- Check Task Scheduler for "MyPCMonitor" task
- Verify task is enabled and state is "Ready" or "Running"

**No data at API?**
- Check `C:\ProgramData\MyAgent\error.log`
- Verify registry config: `Get-ItemProperty "HKLM:\SOFTWARE\MyMonitoringAgent"`
- Check queue file: `Get-Content "C:\ProgramData\MyAgent\queue.jsonl"`
- Run `check-agent-status.ps1` for full diagnostics

**Queue file growing?**
- Check network connectivity
- Verify API endpoint is responding
- Check API key is valid
- Review error log for details

## Files

- `Agent.ps1` - Main agent script
- `Install-Wizard.ps1` - GUI installer
- `Install-Silent.ps1` - Command-line installer
- `Update-Agent.ps1` - Update script
- `Uninstall-Agent.ps1` - Uninstall script
- `check-agent-status.ps1` - Status checker
- `RunAgentHidden.vbs` - VBScript wrapper to hide window

## Security

- Runs as current user (not SYSTEM)
- API key stored in HKLM registry (admins only)
- Only sends system info (no sensitive user data)
- Use HTTPS endpoints for encrypted transmission
