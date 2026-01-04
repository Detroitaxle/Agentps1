# Installation Guide - PC Monitoring Agent

This guide provides step-by-step instructions for installing the PC Monitoring Agent on Windows 11 systems.

## Prerequisites

- **Windows 11** (PowerShell 5.1 is pre-installed)
- **Administrator privileges** (required for installation)
- **API Endpoint URL** and **API Key** from your monitoring service

## Installation Methods

### Method 1: GUI Installation Wizard (Recommended)

The GUI Installation Wizard provides the easiest and most user-friendly installation experience.

#### Steps:

1. **Extract the ZIP package** to a folder on your computer

2. **Right-click** on `Install-Wizard.ps1` and select **"Run with PowerShell"**
   - If you see a security warning, you may need to:
     - Right-click → Properties → Unblock (if available)
     - Or run from PowerShell as Administrator: `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process` then run the script

3. **Enter your configuration:**
   - **API Endpoint URL**: The full URL to your monitoring API (e.g., `https://api.example.com/heartbeat`)
   - **API Key**: Your authentication key for the API
   - **Agent.ps1 Location**: Defaults to `C:\Program Files\MyAgent\Agent.ps1` (you can change this if needed)

4. **Test Connection** (Optional but recommended):
   - Click the "Test Connection" button to verify your API credentials
   - This helps ensure the installation will work correctly

5. **Install**:
   - Click the "Install" button
   - The wizard will:
     - Create registry keys with your configuration
     - Create necessary directories
     - Copy Agent.ps1 to the specified location
     - Create and start the scheduled task
   - A success message will appear when complete

6. **Verification**:
   - The agent starts immediately after installation
   - It will continue running after system reboots
   - Check Task Scheduler: Open Task Scheduler → Task Scheduler Library → Look for "MyPCMonitor"

### Method 2: Silent Installation (Optional)

Use the silent installer for command-line installation or batch deployments.

#### Steps:

1. **Open PowerShell as Administrator**

2. **Navigate to the extracted package directory**

3. **Run the installation command:**
   ```powershell
   .\Install-Silent.ps1 -ApiUrl "https://your-api-endpoint.com/heartbeat" -ApiKey "your-api-key-here"
   ```

4. **Optional parameters:**
   ```powershell
   # Specify custom script path
   .\Install-Silent.ps1 -ApiUrl "https://api.example.com/heartbeat" -ApiKey "your-key" -ScriptPath "C:\Custom\Path\Agent.ps1"
   ```

5. **Check installation log:**
   - Log file: `C:\ProgramData\MyAgent\install.log`
   - Exit code: 0 = success, non-zero = failure

#### Example Output:
```
[2024-01-15 14:30:45] [INFO] Starting silent installation...
[2024-01-15 14:30:45] [INFO] API URL: https://api.example.com/heartbeat
[2024-01-15 14:30:45] [INFO] Creating registry keys...
[2024-01-15 14:30:45] [INFO] Scheduled task registered: MyPCMonitor
[2024-01-15 14:30:45] [SUCCESS] Installation completed successfully!
```

## Configuration

After installation, configuration is stored in:
- **Registry Path**: `HKLM:\SOFTWARE\MyMonitoringAgent`
  - `ApiUrl`: Your API endpoint URL
  - `ApiKey`: Your API key

To modify configuration, you can:
1. Re-run the installation wizard (it will update existing configuration)
2. Manually edit registry keys (requires Administrator privileges)
3. Use the silent installer again with new values

## Verification

### Check Scheduled Task

1. Open **Task Scheduler** (search for "Task Scheduler" in Start menu)
2. Navigate to **Task Scheduler Library**
3. Look for task named **"MyPCMonitor"**
4. Verify:
   - Status: Running
   - Triggers: Every 1 minute
   - Actions: Runs PowerShell script

### Check Data Directory

- Location: `C:\ProgramData\MyAgent\`
- Files:
  - `error.log` - Error logs (if any errors occur)
  - `queue.jsonl` - Offline queue (created when API is unavailable)
  - `last_send.txt` - Last successful heartbeat timestamp

### Check Registry

Open Registry Editor (regedit) as Administrator:
- Navigate to: `HKEY_LOCAL_MACHINE\SOFTWARE\MyMonitoringAgent`
- Verify `ApiUrl` and `ApiKey` values are set correctly

## Uninstallation

### Using the Uninstaller Script

1. **Open PowerShell as Administrator**

2. **Navigate to the package directory**

3. **Run the uninstaller:**
   ```powershell
   .\uninstall.ps1
   ```
   This removes:
   - Scheduled task
   - Registry keys
   - Script file
   - Keeps data files (queue, logs)

4. **Remove data files (optional):**
   ```powershell
   .\uninstall.ps1 -RemoveDataFiles $true
   ```
   This also removes the data directory and all files.

### Manual Uninstallation

1. **Stop and Remove Scheduled Task:**
   - Open Task Scheduler
   - Find "MyPCMonitor" task
   - Right-click → Delete

2. **Remove Registry Keys:**
   - Open Registry Editor (regedit) as Administrator
   - Navigate to `HKEY_LOCAL_MACHINE\SOFTWARE\MyMonitoringAgent`
   - Delete the `MyMonitoringAgent` key

3. **Remove Script File:**
   - Delete: `C:\Program Files\MyAgent\Agent.ps1`
   - Delete directory if empty: `C:\Program Files\MyAgent\`

4. **Remove Data Files (optional):**
   - Delete: `C:\ProgramData\MyAgent\`

## Troubleshooting

### Installation Fails with "Access Denied"

- **Solution**: Ensure you're running PowerShell as Administrator
- Right-click PowerShell → "Run as Administrator"

### "Execution Policy" Error

- **Solution**: Run this command in PowerShell (as Administrator):
  ```powershell
  Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process
  ```
  Then run the installer again.

### Scheduled Task Not Running

1. Check Task Scheduler → Task Scheduler Library → MyPCMonitor
2. Check the "Last Run Result" column
3. View the task history for errors
4. Check error log: `C:\ProgramData\MyAgent\error.log`

### API Connection Issues

1. Verify API URL and API Key in registry:
   ```powershell
   Get-ItemProperty "HKLM:\SOFTWARE\MyMonitoringAgent"
   ```

2. Test API connectivity:
   ```powershell
   $url = (Get-ItemProperty "HKLM:\SOFTWARE\MyMonitoringAgent").ApiUrl
   $key = (Get-ItemProperty "HKLM:\SOFTWARE\MyMonitoringAgent").ApiKey
   Invoke-WebRequest -Uri $url -Headers @{"X-API-KEY"=$key} -Method GET
   ```

3. Check error log for specific error messages:
   ```powershell
   Get-Content "C:\ProgramData\MyAgent\error.log"
   ```

### Agent Not Sending Heartbeats

1. Check if scheduled task is enabled and running
2. Check error log: `C:\ProgramData\MyAgent\error.log`
3. Check queue file: `C:\ProgramData\MyAgent\queue.jsonl` (if exists, API may be unreachable)
4. Verify network connectivity
5. Verify API endpoint is accessible

### Script Path Issues

If you get "Agent.ps1 not found" errors:
- Ensure `Agent.ps1` is in the same directory as the installer
- Or specify the correct path using `-ScriptPath` parameter
- Verify the target directory exists and is writable

## Support

For additional help:
1. Check the error log: `C:\ProgramData\MyAgent\error.log`
2. Review the README.md file for detailed information
3. Check Task Scheduler for task execution history

## Security Notes

- The agent runs as SYSTEM account for maximum privileges
- API key is stored in registry (HKLM) - protect registry access
- Script files are stored in Program Files (requires Administrator to modify)
- Data files are in ProgramData (standard Windows location)

