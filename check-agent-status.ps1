# Check Agent Status Script
# Shows current agent status, last send time, queue status, and recent errors

Write-Host "=== Agent Status Check ===" -ForegroundColor Cyan
Write-Host ""

# Check Scheduled Task
Write-Host "Scheduled Task Status:" -ForegroundColor Yellow
try {
    $task = Get-ScheduledTask -TaskName "MyPCMonitor" -ErrorAction Stop
    $taskInfo = Get-ScheduledTaskInfo -TaskName "MyPCMonitor"
    
    Write-Host "  Task Name: $($task.TaskName)" -ForegroundColor Gray
    Write-Host "  State: $($task.State)" -ForegroundColor $(if ($task.State -eq "Running") { "Green" } else { "Yellow" })
    Write-Host "  Last Run: $($taskInfo.LastRunTime)" -ForegroundColor Gray
    Write-Host "  Next Run: $($taskInfo.NextRunTime)" -ForegroundColor Gray
    Write-Host "  Last Result: $($taskInfo.LastTaskResult)" -ForegroundColor $(if ($taskInfo.LastTaskResult -eq 0) { "Green" } else { "Red" })
} catch {
    Write-Host "  [ERROR] Scheduled task not found!" -ForegroundColor Red
}
Write-Host ""

# Check Registry Configuration
Write-Host "Registry Configuration:" -ForegroundColor Yellow
try {
    $apiUrl = (Get-ItemProperty -Path "HKLM:\SOFTWARE\MyMonitoringAgent" -Name "ApiUrl" -ErrorAction Stop).ApiUrl
    $apiKey = (Get-ItemProperty -Path "HKLM:\SOFTWARE\MyMonitoringAgent" -Name "ApiKey" -ErrorAction Stop).ApiKey
    
    Write-Host "  API URL: $apiUrl" -ForegroundColor Gray
    Write-Host "  API Key: $($apiKey.Substring(0, [Math]::Min(20, $apiKey.Length)))..." -ForegroundColor Gray
} catch {
    Write-Host "  [ERROR] Registry configuration not found!" -ForegroundColor Red
}
Write-Host ""

# Check Data Directory
$DataDirectory = "C:\ProgramData\MyAgent"
$LastSendFile = Join-Path $DataDirectory "last_send.txt"
$QueueFile = Join-Path $DataDirectory "queue.jsonl"
$ErrorLogFile = Join-Path $DataDirectory "error.log"

Write-Host "Data Directory Status:" -ForegroundColor Yellow
if (Test-Path $DataDirectory) {
    Write-Host "  Directory: $DataDirectory [EXISTS]" -ForegroundColor Green
} else {
    Write-Host "  Directory: $DataDirectory [NOT FOUND]" -ForegroundColor Red
}
Write-Host ""

# Check Last Send Time
Write-Host "Last Send Status:" -ForegroundColor Yellow
if (Test-Path $LastSendFile) {
    try {
        $content = Get-Content $LastSendFile -Raw
        $trimmed = $content.Trim()
        if ($trimmed) {
            try {
                $lastSend = [DateTime]::Parse($trimmed, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
            } catch {
                $lastSend = [DateTime]::Parse($trimmed)
            }
            $timeSince = [DateTime]::UtcNow - $lastSend
            Write-Host "  Last Send: $lastSend UTC" -ForegroundColor Gray
            Write-Host "  Time Since: $([Math]::Floor($timeSince.TotalMinutes)) minutes ago" -ForegroundColor $(if ($timeSince.TotalMinutes -lt 5) { "Green" } else { "Yellow" })
        } else {
            Write-Host "  [WARNING] File exists but is empty" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  [ERROR] Failed to read last send time: $($_.Exception.Message)" -ForegroundColor Red
    }
} else {
    Write-Host "  [INFO] No last send record (agent may not have sent yet)" -ForegroundColor Yellow
}
Write-Host ""

# Check Queue Status
Write-Host "Queue Status:" -ForegroundColor Yellow
if (Test-Path $QueueFile) {
    try {
        $queuedItems = @(Get-Content $QueueFile)
        $queuedItems = $queuedItems | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $fileInfo = Get-Item $QueueFile
        $sizeKB = [Math]::Round($fileInfo.Length / 1KB, 2)
        
        Write-Host "  Queue File: [EXISTS]" -ForegroundColor Yellow
        Write-Host "  Queued Items: $($queuedItems.Count)" -ForegroundColor $(if ($queuedItems.Count -eq 0) { "Green" } else { "Yellow" })
        Write-Host "  File Size: $sizeKB KB" -ForegroundColor Gray
        
        if ($queuedItems.Count -gt 0) {
            Write-Host "  [WARNING] There are $($queuedItems.Count) items waiting to be sent!" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  [ERROR] Failed to read queue: $($_.Exception.Message)" -ForegroundColor Red
    }
} else {
    Write-Host "  Queue File: [EMPTY - No queued items]" -ForegroundColor Green
}
Write-Host ""

# Check Error Log
Write-Host "Recent Errors (last 10 lines):" -ForegroundColor Yellow
if (Test-Path $ErrorLogFile) {
    try {
        $errors = Get-Content $ErrorLogFile -Tail 10
        if ($errors.Count -gt 0) {
            foreach ($error in $errors) {
                Write-Host "  $error" -ForegroundColor $(if ($error -match "Error|Failed") { "Red" } else { "Gray" })
            }
        } else {
            Write-Host "  [INFO] No errors logged" -ForegroundColor Green
        }
    } catch {
        Write-Host "  [ERROR] Failed to read error log: $($_.Exception.Message)" -ForegroundColor Red
    }
} else {
    Write-Host "  [INFO] No error log file (no errors yet)" -ForegroundColor Green
}
Write-Host ""

# Check Current System State
Write-Host "Current System State:" -ForegroundColor Yellow
try {
    # Get idle time
    $csharpCode = @"
using System;
using System.Runtime.InteropServices;
public class IdleTimeHelper {
    [DllImport("user32.dll")]
    static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO {
        public uint cbSize;
        public uint dwTime;
    }
    public static int GetIdleTimeSeconds() {
        LASTINPUTINFO lastInput = new LASTINPUTINFO();
        lastInput.cbSize = (uint)Marshal.SizeOf(lastInput);
        if (GetLastInputInfo(ref lastInput)) {
            uint lastInputTicks = lastInput.dwTime;
            uint currentTicks = (uint)Environment.TickCount;
            uint idleTicks = currentTicks - lastInputTicks;
            return (int)(idleTicks / 1000);
        }
        return 0;
    }
}
"@
    Add-Type -TypeDefinition $csharpCode -ErrorAction SilentlyContinue
    $idleSeconds = [IdleTimeHelper]::GetIdleTimeSeconds()
    
    $computerId = (Get-CimInstance Win32_ComputerSystemProduct).UUID
    $computerName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { "UNKNOWN" }
    $username = try {
        $u = (Get-CimInstance Win32_ComputerSystem).UserName
        if ($u -match '\\') { $u.Split('\')[-1] } else { $u }
    } catch {
        if ($env:USERNAME) { $env:USERNAME } else { "SYSTEM" }
    }
    $ticks = [Environment]::TickCount64
    $uptime = [TimeSpan]::FromMilliseconds($ticks)
    $uptimeFormatted = if ($uptime.Days -gt 0) {
        "{0:00}:{1:00}:{2:00}:{3:00}" -f $uptime.Days, $uptime.Hours, $uptime.Minutes, $uptime.Seconds
    } else {
        $uptime.ToString("hh\:mm\:ss")
    }
    
    Write-Host "  Computer ID: $computerId" -ForegroundColor Gray
    Write-Host "  Computer Name: $computerName" -ForegroundColor Gray
    Write-Host "  Username: $username" -ForegroundColor Gray
    Write-Host "  Uptime: $uptimeFormatted" -ForegroundColor Gray
    Write-Host "  Idle Time: $idleSeconds seconds ($([Math]::Floor($idleSeconds / 60)) minutes)" -ForegroundColor $(if ($idleSeconds -gt 600) { "Yellow" } else { "Green" })
    
    # Check if adaptive polling would skip
    if (Test-Path $LastSendFile) {
        try {
            $content = Get-Content $LastSendFile -Raw
            $trimmed = $content.Trim()
            if ($trimmed) {
                try {
                    $lastSend = [DateTime]::Parse($trimmed, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
                } catch {
                    $lastSend = [DateTime]::Parse($trimmed)
                }
                $timeSince = ([DateTime]::UtcNow - $lastSend).TotalSeconds
                
                if ($idleSeconds -gt 600 -and $timeSince -lt 300) {
                    Write-Host "  Adaptive Polling: [ACTIVE] - Next heartbeat will be skipped (idle > 10min, last send < 5min ago)" -ForegroundColor Yellow
                } else {
                    Write-Host "  Adaptive Polling: [INACTIVE] - Next heartbeat will be sent normally" -ForegroundColor Green
                }
            }
        } catch {}
    }
} catch {
    Write-Host "  [ERROR] Failed to get system state: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

Write-Host "=== End Status Check ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

