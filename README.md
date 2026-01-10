# PC Monitoring Agent

A lightweight PowerShell monitoring agent that sends system heartbeat data to a remote API. Runs as a Windows Scheduled Task with offline queuing and adaptive polling.

## Features

- **Automated Installation**: GUI wizard or silent installer for easy deployment
- **Offline Queuing**: Caches failed requests and retries when connectivity returns
- **Adaptive Polling**: Reduces API calls during idle periods
- **Hardware Identity**: Uses hardware UUID for persistent device identification
- **Low Resource Usage**: Native .NET methods for minimal CPU/memory overhead

## Quick Start

### Option 1: GUI Wizard (Recommended)

1. **Right-click** `Install-Wizard.bat` and select **"Run as administrator"**
2. Enter your API endpoint URL and API key
3. Test connection (optional)
4. Click Install

### Option 2: Silent Installation

1. Edit `Install-Silent.ps1` configuration section:
   ```powershell
   $ApiUrl = "https://your-api-endpoint.com/api/heartbeat"
   $ApiKey = "your-api-key-here"
   ```
2. Run as administrator:
   ```powershell
   .\Install-Silent.ps1
   ```

### Requirements

- Windows PowerShell 5.1+
- Administrator privileges
- Network connectivity to API endpoint

## How It Works

The agent runs every minute via Windows Task Scheduler as SYSTEM account. It collects and sends:

- **Hardware UUID**: Persistent device identifier
- **Computer Name**: Current hostname
- **Username**: Current logged-in user
- **System Uptime**: Formatted as HH:mm:ss or dd:HH:mm:ss
- **Idle Time**: Seconds since last user input
- **Timestamp**: ISO 8601 UTC format

### Data Payload Example

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

## Configuration

Configuration is stored in Windows Registry:

- **Registry Path**: `HKLM:\SOFTWARE\MyMonitoringAgent`
- **ApiUrl**: Your API endpoint
- **ApiKey**: Authentication key

Data files are stored in:

- **Directory**: `C:\ProgramData\MyAgent\`
- **Queue**: `queue.jsonl` (offline requests)
- **Error Log**: `error.log`
- **Last Send**: `last_send.txt` (timestamp tracking)

## Agent Behavior

### Offline Queuing
- Failed API requests are saved to queue file (max 10MB)
- Queue is processed after successful heartbeats (50 items at a time)
- Oldest entries are removed first when limit is reached

### Adaptive Polling
- Normal mode: Sends heartbeat every minute
- Idle mode: When idle > 10 minutes, sends every 5 minutes
- Reduces server load during inactive periods

### Performance
- Native .NET methods for uptime (no WMI queries)
- Direct Windows API calls for idle detection
- Minimal CPU and memory footprint

## Management

### Check Status
```powershell
.\check-agent-status.ps1
```

### Update Agent
```powershell
.\update-agent.bat
```

### Uninstall
```powershell
.\uninstall.bat
```

## Troubleshooting

**Task not running?**
```powershell
Get-ScheduledTask -TaskName "MyPCMonitor"
Get-ScheduledTaskInfo -TaskName "MyPCMonitor"
```

**Check errors:**
```powershell
Get-Content "C:\ProgramData\MyAgent\error.log"
```

**Verify configuration:**
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\MyMonitoringAgent"
```

**Check offline queue:**
```powershell
Get-Content "C:\ProgramData\MyAgent\queue.jsonl"
```

## API Requirements

Your API endpoint must:
- Accept POST requests with `Content-Type: application/json`
- Use `X-API-KEY` header for authentication
- Return 2xx status codes for success

## Security

- Runs as SYSTEM account - ensure script integrity
- API key stored in HKLM registry
- No sensitive user data transmitted (username only)
- Standard ProgramData permissions applied

## Files

| File | Purpose |
|------|---------|
| `Agent.ps1` | Main monitoring agent |
| `Install-Wizard.bat` | GUI installer launcher |
| `Install-Wizard.ps1` | GUI installer script |
| `Install-Silent.ps1` | Silent installer |
| `check-agent-status.ps1` | Status checker |
| `update-agent.bat` | Update utility |
| `uninstall.bat` | Uninstaller |

## License

MIT License - See repository for details