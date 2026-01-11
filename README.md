# PC Monitoring Agent

A lightweight PowerShell-based monitoring agent that automatically sends system heartbeat data to a remote API endpoint. The agent runs continuously in the background, collecting system information and transmitting it to your monitoring server at regular intervals.

## Overview

This agent is designed to provide continuous monitoring of Windows computers by sending periodic status updates to a remote API. It operates as a Windows Scheduled Task that runs every minute, collecting system metrics and transmitting them via HTTP POST requests.

### What It Does

The agent performs the following operations:

1. **Collects System Information**: Every minute, the agent gathers current system state including:
   - Hardware UUID (persistent computer identifier)
   - Computer hostname
   - Currently logged-in username
   - System uptime (time since last reboot)
   - User idle time (seconds since last keyboard/mouse input)
   - Current UTC timestamp

2. **Sends Heartbeat Data**: Packages the collected information into a JSON payload and sends it to your configured API endpoint via HTTPS/HTTP POST request.

3. **Handles Failures Gracefully**: If the API is unreachable or returns an error, failed requests are saved to a local queue file and automatically retried when connectivity is restored.

4. **Adapts to System Activity**: Reduces API call frequency when the computer is idle to minimize server load while maintaining monitoring coverage.

## Features

### Automated Installation
Two installation methods are available:
- **GUI Wizard**: Interactive Windows Forms installer with connection testing
- **Silent Installer**: Command-line installer for automated deployment

### Offline Queuing System
- Failed API requests are automatically saved to a local queue file (`queue.jsonl`)
- Queue is processed in batches of 100 items after successful heartbeats
- Queue file has a maximum size limit of 10MB to prevent disk space issues
- Oldest entries are automatically trimmed when the limit is reached
- Queue persists across system reboots

### Adaptive Polling
The agent intelligently adjusts its polling frequency based on system activity:
- **Normal Mode**: Sends heartbeat every 1 minute when the computer is in active use
- **Idle Mode**: When the computer has been idle for more than 10 minutes, the agent reduces polling to once every 5 minutes
- This reduces server load during inactive periods while maintaining monitoring coverage

### Hardware-Based Identity
- Uses the computer's hardware UUID (from BIOS/motherboard) as a persistent identifier
- This UUID remains constant even after OS reinstallation or hard drive replacement
- Allows reliable tracking of the same physical computer across system changes

### Low Resource Usage
- Uses native .NET methods for system information gathering (no WMI queries for uptime)
- Direct Windows API calls for idle time detection
- Minimal CPU and memory footprint
- Runs as a lightweight PowerShell script

## Installation

### Prerequisites

- Windows PowerShell 5.1 or later
- Administrator privileges (required for installation only)
- Network connectivity to your API endpoint
- Valid API endpoint URL and API key

### Option 1: GUI Installation Wizard (Recommended)

The GUI installer provides a user-friendly interface with connection testing:

1. **Right-click** `Install-Wizard.bat` and select **"Run as administrator"**
2. Enter your API endpoint URL (must be a valid HTTP or HTTPS URL)
3. Enter your API key (displayed as masked characters)
4. Optionally test the connection using the "Test Connection" button
5. Click "Install" to complete the installation

The installer will:
- Create registry entries for configuration
- Copy the agent script to `C:\Program Files\MyAgent\Agent.ps1`
- Create a Windows Scheduled Task named "MyPCMonitor"
- Start the agent immediately

### Option 2: Silent Installation

For automated deployments or scripting:

1. Edit `Install-Silent.ps1` and modify the parameters at the top:
   ```powershell
   .\Install-Silent.ps1 -ApiUrl "https://your-api-endpoint.com/api/heartbeat" -ApiKey "your-api-key-here"
   ```

2. Run as administrator:
   ```powershell
   .\Install-Silent.ps1 -ApiUrl "https://your-api-endpoint.com/api/heartbeat" -ApiKey "your-api-key-here"
   ```

The silent installer performs the same operations as the GUI installer but without user interaction.

## How It Works

### Execution Model

The agent runs as a Windows Scheduled Task that executes every minute. The task is configured to:
- Run as the current user account (not SYSTEM)
- Execute even when the user is logged out (if configured)
- Continue running on battery power
- Run hidden (no visible windows)

### Data Collection Process

Each execution cycle performs the following steps:

1. **Configuration Loading**: Reads API URL and API key from Windows Registry (`HKLM:\SOFTWARE\MyMonitoringAgent`)

2. **Idle Time Check**: Calculates seconds since last user input using Windows API calls (works even when running as SYSTEM via session impersonation)

3. **Adaptive Polling Evaluation**: 
   - If idle time > 10 minutes AND last successful send < 5 minutes ago → skip this heartbeat
   - Otherwise → proceed with heartbeat

4. **System Information Gathering**:
   - Hardware UUID: Retrieved from WMI `Win32_ComputerSystemProduct`
   - Computer Name: From `$env:COMPUTERNAME` environment variable
   - Username: From WMI `Win32_ComputerSystem` or environment variable (domain stripped if present)
   - Uptime: Calculated from `Environment.TickCount64` (system uptime in milliseconds)
   - Idle Time: From Windows `GetLastInputInfo` API
   - Timestamp: Current UTC time in ISO 8601 format

5. **Payload Creation**: Packages data into JSON format

6. **API Transmission**: Sends POST request with:
   - Headers: `Content-Type: application/json`, `X-API-KEY: <your-key>`
   - Body: JSON payload

7. **Queue Processing**: If transmission succeeds, processes any queued items from previous failures

8. **Error Handling**: If transmission fails, saves the payload to queue file for retry

### Data Payload Format

Each heartbeat sends a JSON payload with the following structure:

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

**Field Descriptions:**
- `computerId`: Hardware UUID (GUID format) - persistent identifier for this computer
- `computerName`: Windows hostname
- `username`: Currently logged-in username (domain portion removed if present)
- `online`: Always `true` (indicates agent is running)
- `pcStatus`: Always `"on"` (indicates computer is powered on)
- `pcUptime`: System uptime formatted as `HH:mm:ss` (hours:minutes:seconds) or `dd:HH:mm:ss` (days:hours:minutes:seconds) if uptime exceeds 24 hours
- `idleTimeSeconds`: Number of seconds since last keyboard/mouse input
- `timestamp`: UTC timestamp in ISO 8601 format with timezone indicator (Z)

## Configuration

### Registry Settings

Configuration is stored in Windows Registry at:
- **Path**: `HKLM:\SOFTWARE\MyMonitoringAgent`
- **Keys**:
  - `ApiUrl`: Your API endpoint URL (string)
  - `ApiKey`: Your API authentication key (string)

These values are set during installation and persist across reboots.

### Data Directory

Runtime data is stored in:
- **Directory**: `C:\ProgramData\MyAgent\`

**Files:**
- `queue.jsonl`: Queue file containing failed requests (JSON Lines format, one JSON object per line)
- `error.log`: Error log file with timestamps
- `last_send.txt`: Timestamp of last successful API transmission (ISO 8601 format)

The data directory and files are created automatically when the agent first runs.

## Agent Behavior Details

### Offline Queuing Mechanism

When the API is unreachable or returns an error:

1. **Failure Detection**: The agent catches the exception from the HTTP request
2. **Queue Storage**: The JSON payload is appended to `queue.jsonl` (one line per payload)
3. **Queue Processing**: On subsequent successful heartbeats, the agent processes queued items:
   - Reads all items from the queue file
   - Processes them in batches of 100 items
   - Attempts to send each item to the API
   - Items that succeed are removed from the queue
   - Items that fail remain in the queue for the next cycle
4. **Queue Management**: 
   - Queue file is deleted when all items are successfully sent
   - If queue exceeds 10MB, oldest entries are trimmed (keeps most recent ~20,000 lines)
   - Queue persists across system reboots

### Adaptive Polling Logic

The adaptive polling feature reduces API calls when the computer is idle:

**Conditions for Idle Mode:**
- System idle time > 10 minutes (600 seconds)
- AND last successful send was < 5 minutes ago (300 seconds)

**Behavior:**
- When in idle mode, the agent skips creating and sending a new heartbeat
- However, queue processing still occurs (to retry failed items)
- When idle mode conditions are no longer met, normal 1-minute polling resumes

This reduces server load during inactive periods (nights, weekends, etc.) while ensuring active monitoring when users return.

### Error Handling

The agent implements comprehensive error handling:

- **Configuration Errors**: Logged to error log, agent exits
- **API Transmission Errors**: Logged to error log, payload queued for retry
- **Queue Processing Errors**: Logged to error log, queue file preserved
- **System Information Errors**: Logged to error log, agent continues with default values where possible

All errors are logged to `C:\ProgramData\MyAgent\error.log` with timestamps.

## Management

### Check Agent Status

To view the current status of the agent:

```powershell
.\check-agent-status.ps1
```

This script displays:
- Scheduled task status and last run time
- Registry configuration (API URL, masked API key)
- Data directory status
- Last successful send timestamp
- Queue status (number of queued items, file size)
- Recent error log entries
- Current system state (computer ID, name, username, uptime, idle time)
- Adaptive polling status

### Update Agent Script

To update the agent script with a newer version:

1. Replace `Agent.ps1` in the repository directory
2. Run as administrator:
   ```powershell
   .\update-agent.bat
   ```

This script:
- Backs up the current installed version
- Copies the new version to the installation directory
- Verifies the copy with SHA256 hash comparison
- The new version will be used on the next scheduled run (within 1 minute)

### Uninstall

To remove the agent:

```powershell
.\uninstall.bat
```

Run as administrator. This will:
- Stop and remove the scheduled task
- Remove registry configuration keys
- Remove the agent script file (and directory if empty)
- **Note**: Data directory (`C:\ProgramData\MyAgent`) is NOT removed by default (queue and logs preserved)

To also remove data files, edit `uninstall.bat` and set `$RemoveDataFiles = $true`.

## Troubleshooting

### Agent Not Running

Check if the scheduled task exists and is enabled:

```powershell
Get-ScheduledTask -TaskName "MyPCMonitor"
Get-ScheduledTaskInfo -TaskName "MyPCMonitor"
```

Verify the task state is "Ready" or "Running". If missing, reinstall the agent.

### No Data Received at API

1. **Check Error Log**:
   ```powershell
   Get-Content "C:\ProgramData\MyAgent\error.log"
   ```

2. **Verify Configuration**:
   ```powershell
   Get-ItemProperty "HKLM:\SOFTWARE\MyMonitoringAgent"
   ```

3. **Check Queue File**:
   ```powershell
   Get-Content "C:\ProgramData\MyAgent\queue.jsonl"
   ```
   If items are queued, the API may be unreachable or rejecting requests.

4. **Test Connectivity**: Use the status check script or manually test the API endpoint

### Queue File Growing Large

If the queue file continues to grow:
- Check network connectivity to the API endpoint
- Verify API endpoint is responding correctly
- Check API key is valid
- Review error log for specific error messages
- Queue is automatically trimmed at 10MB, but continuous failures indicate a problem

### Idle Time Not Detected

If idle time always shows 0:
- This may occur when running as SYSTEM account without active user session
- The agent uses session impersonation to detect idle time, which may fail in some configurations
- Idle time detection failure does not prevent the agent from functioning (idle time will be 0)

## API Requirements

Your API endpoint must meet these requirements:

1. **Accept POST Requests**: The endpoint must accept HTTP POST requests
2. **Content-Type**: Must accept `application/json` content type
3. **Authentication**: Must accept API key authentication via `X-API-KEY` header
4. **Response Codes**: Must return HTTP 2xx status codes (200, 201, 202, etc.) for successful requests
5. **Request Body**: Must accept JSON payload in the format described above

**Example API Request:**
```
POST /api/heartbeat HTTP/1.1
Host: your-api-endpoint.com
Content-Type: application/json
X-API-KEY: your-api-key-here
Content-Length: 234

{"computerId":"550e8400-e29b-41d4-a716-446655440000","computerName":"DESKTOP-ABC123","username":"jsmith","online":true,"pcStatus":"on","pcUptime":"05:23:45","idleTimeSeconds":120,"timestamp":"2024-01-15T14:30:45.1234567Z"}
```

## Security Considerations

- **Account Context**: The agent runs as the current user account (not SYSTEM), so it operates with the privileges of the installing user
- **Registry Storage**: API key is stored in HKLM registry (accessible to administrators only)
- **Data Transmission**: Only system information is transmitted (no sensitive user data beyond username)
- **Network Security**: Use HTTPS endpoints to encrypt data in transit
- **File Permissions**: Data directory uses standard ProgramData permissions
- **Script Integrity**: Ensure script files are not modified by unauthorized users

## File Structure

| File | Purpose |
|------|---------|
| `Agent.ps1` | Main monitoring agent script (executed by scheduled task) |
| `Install-Wizard.bat` | Batch file launcher for GUI installer (handles execution policy) |
| `Install-Wizard.ps1` | GUI installer script with Windows Forms interface |
| `Install-Silent.ps1` | Silent/command-line installer script |
| `check-agent-status.ps1` | Status checking and diagnostic script |
| `update-agent.bat` | Script update utility |
| `uninstall.bat` | Uninstaller script |
| `README.md` | This documentation file |

## Technical Details

### Uptime Calculation

System uptime is calculated using `Environment.TickCount64`, which provides the number of milliseconds since system boot. This is more efficient than WMI queries and avoids potential performance issues.

### Idle Time Detection

Idle time detection uses the Windows `GetLastInputInfo` API, which returns the timestamp of the last keyboard or mouse input. The agent:
1. First attempts direct API call (works in user context)
2. If that fails (e.g., running as SYSTEM), impersonates the active console session and retries
3. Calculates idle time as the difference between current time and last input time
4. Handles 32-bit tick count wraparound (occurs every ~49.7 days)

### Queue File Format

The queue file uses JSON Lines format (`.jsonl`):
- Each line contains one complete JSON object
- Lines are separated by newline characters
- Empty lines are ignored
- Format allows efficient appending and line-by-line processing

## License

MIT License - See repository for details
