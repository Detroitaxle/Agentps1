#Requires -Version 5.1
<#
.SYNOPSIS
    Background monitoring agent that sends heartbeat data to a remote API.
.DESCRIPTION
    Runs every minute via Task Scheduler as SYSTEM account. Implements adaptive
    polling, offline queuing, and efficient resource usage.
#>

#region Configuration
$RegistryPath = "HKLM:\SOFTWARE\MyMonitoringAgent"
$DataDirectory = "C:\ProgramData\MyAgent"
$QueueFile = Join-Path $DataDirectory "queue.jsonl"
$ErrorLogFile = Join-Path $DataDirectory "error.log"
$LastSendFile = Join-Path $DataDirectory "last_send.txt"
$MaxQueueSizeMB = 10
$BatchSize = 50
$AdaptivePollingThreshold = 600  # seconds (10 minutes)
$AdaptivePollingInterval = 300   # seconds (5 minutes)
#endregion

#region Helper Functions

function Write-ErrorLog {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $Message"
    try {
        Add-Content -Path $ErrorLogFile -Value $LogMessage -ErrorAction Stop
    } catch {
        # If we can't write to error log, there's not much we can do
    }
}

function Get-ConfigFromRegistry {
    try {
        $apiUrl = (Get-ItemProperty -Path $RegistryPath -Name "ApiUrl" -ErrorAction Stop).ApiUrl
        $apiKey = (Get-ItemProperty -Path $RegistryPath -Name "ApiKey" -ErrorAction Stop).ApiKey
        
        if (-not $apiUrl -or -not $apiKey) {
            Write-ErrorLog "Config Error: ApiUrl or ApiKey is empty in registry"
            exit 1
        }
        
        return @{
            ApiUrl = $apiUrl
            ApiKey = $apiKey
        }
    } catch {
        Write-ErrorLog "Config Error: Registry keys not found at $RegistryPath"
        exit 1
    }
}

function Get-ComputerUUID {
    try {
        $uuid = (Get-CimInstance Win32_ComputerSystemProduct).UUID
        return $uuid
    } catch {
        Write-ErrorLog "Error: Failed to retrieve hardware UUID - $($_.Exception.Message)"
        return $null
    }
}

function Get-UptimeFormatted {
    try {
        $ticks = [Environment]::TickCount64
        $uptime = [TimeSpan]::FromMilliseconds($ticks)
        # Format as dd:hh:mm:ss or hh:mm:ss if less than 24 hours
        if ($uptime.Days -gt 0) {
            return "{0:00}:{1:00}:{2:00}:{3:00}" -f $uptime.Days, $uptime.Hours, $uptime.Minutes, $uptime.Seconds
        } else {
            return $uptime.ToString("hh\:mm\:ss")
        }
    } catch {
        Write-ErrorLog "Error: Failed to calculate uptime - $($_.Exception.Message)"
        return "00:00:00"
    }
}

function Get-IdleTime {
    # Embed C# code to call Windows API GetLastInputInfo
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
    
    try {
        Add-Type -TypeDefinition $csharpCode -ErrorAction SilentlyContinue
        $idleSeconds = [IdleTimeHelper]::GetIdleTimeSeconds()
        return $idleSeconds
    } catch {
        # If type already exists, just use it
        try {
            $idleSeconds = [IdleTimeHelper]::GetIdleTimeSeconds()
            return $idleSeconds
        } catch {
            Write-ErrorLog "Error: Failed to get idle time - $($_.Exception.Message)"
            return 0
        }
    }
}

function Get-CurrentUsername {
    try {
        $username = (Get-CimInstance Win32_ComputerSystem).UserName
        if (-not $username) {
            $username = if ($env:USERNAME) { $env:USERNAME } else { "SYSTEM" }
        }
        # Extract just the username if it's in DOMAIN\USER format
        if ($username -match '\\') {
            $username = $username.Split('\')[-1]
        }
        return $username
    } catch {
        return if ($env:USERNAME) { $env:USERNAME } else { "SYSTEM" }
    }
}

function Get-LastSendTime {
    if (Test-Path $LastSendFile) {
        try {
            $content = Get-Content $LastSendFile -Raw
            if ($content) {
                $trimmed = $content.Trim()
                if ($trimmed) {
                    # Try parsing as ISO 8601 format (what we write with .ToString("o"))
                    try {
                        $timestamp = [DateTime]::Parse($trimmed, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
                        return $timestamp
                    } catch {
                        # Fallback to standard parse
                        $timestamp = [DateTime]::Parse($trimmed)
                        return $timestamp
                    }
                }
            }
        } catch {
            Write-ErrorLog "Warning: Failed to parse last_send.txt - $($_.Exception.Message)"
        }
    }
    return $null
}

function Set-LastSendTime {
    try {
        $utcNow = [DateTime]::UtcNow
        Set-Content -Path $LastSendFile -Value $utcNow.ToString("o") -ErrorAction Stop
    } catch {
        Write-ErrorLog "Warning: Failed to update last_send.txt - $($_.Exception.Message)"
    }
}

function Test-AdaptivePollingSkip {
    param(
        [int]$IdleTimeSeconds,
        [datetime]$LastSendTime
    )
    
    if ($IdleTimeSeconds -le $AdaptivePollingThreshold) {
        return $false
    }
    
    if ($null -eq $LastSendTime) {
        return $false
    }
    
    $timeSinceLastSend = ([DateTime]::UtcNow - $LastSendTime).TotalSeconds
    if ($timeSinceLastSend -lt $AdaptivePollingInterval) {
        return $true
    }
    
    return $false
}

function Add-ToQueue {
    param([string]$JsonPayload)
    
    try {
        # Ensure directory exists
        $null = New-Item -ItemType Directory -Path $DataDirectory -Force -ErrorAction Stop
        
        # Check queue file size
        if (Test-Path $QueueFile) {
            $fileInfo = Get-Item $QueueFile
            $sizeMB = $fileInfo.Length / 1MB
            
            if ($sizeMB -gt $MaxQueueSizeMB) {
                # Read all lines, filter empty lines, keep only the most recent entries
                $allLines = @(Get-Content $QueueFile)
                $allLines = $allLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                $maxLines = [Math]::Floor(($MaxQueueSizeMB * 1MB) / 500)  # Rough estimate: ~500 bytes per line
                $linesToKeep = $allLines | Select-Object -Last $maxLines
                
                # Write back the trimmed queue
                if ($linesToKeep.Count -gt 0) {
                    Set-Content -Path $QueueFile -Value $linesToKeep -ErrorAction Stop
                } else {
                    Remove-Item -Path $QueueFile -Force -ErrorAction Stop
                }
            }
        }
        
        # Append new entry
        Add-Content -Path $QueueFile -Value $JsonPayload -ErrorAction Stop
    } catch {
        Write-ErrorLog "Error: Failed to add to queue - $($_.Exception.Message)"
    }
}

function Send-Heartbeat {
    param(
        [hashtable]$Config,
        [string]$Payload
    )
    
    try {
        $headers = @{
            "Content-Type" = "application/json"
            "X-API-KEY" = $Config.ApiKey
        }
        
        $response = Invoke-RestMethod -Uri $Config.ApiUrl -Method Post -Headers $headers -Body $Payload -ContentType "application/json" -ErrorAction Stop
        return $true
    } catch {
        Write-ErrorLog "API Error: Failed to send heartbeat - $($_.Exception.Message)"
        return $false
    }
}

function Process-Queue {
    param([hashtable]$Config)
    
    if (-not (Test-Path $QueueFile)) {
        return
    }
    
    try {
        $queuedItems = @(Get-Content $QueueFile)
        # Filter out empty lines
        $queuedItems = $queuedItems | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        
        if ($queuedItems.Count -eq 0) {
            Remove-Item -Path $QueueFile -Force -ErrorAction Stop
            return
        }
        
        $headers = @{
            "Content-Type" = "application/json"
            "X-API-KEY" = $Config.ApiKey
        }
        
        $allSucceeded = $true
        $processedCount = 0
        
        # Process in batches of 50
        for ($i = 0; $i -lt $queuedItems.Count; $i += $BatchSize) {
            $batch = $queuedItems[$i..([Math]::Min($i + $BatchSize - 1, $queuedItems.Count - 1))]
            
            foreach ($item in $batch) {
                try {
                    $response = Invoke-RestMethod -Uri $Config.ApiUrl -Method Post -Headers $headers -Body $item -ContentType "application/json" -ErrorAction Stop
                    $processedCount++
                } catch {
                    Write-ErrorLog "Queue Error: Failed to send queued item - $($_.Exception.Message)"
                    $allSucceeded = $false
                    break
                }
            }
            
            if (-not $allSucceeded) {
                break
            }
        }
        
        # Only delete queue file if all items were successfully sent
        if ($allSucceeded -and $processedCount -eq $queuedItems.Count) {
            Remove-Item -Path $QueueFile -Force -ErrorAction Stop
        } else {
            # Remove successfully sent items from queue
            if ($processedCount -gt 0) {
                $remainingItems = $queuedItems | Select-Object -Skip $processedCount
                if ($remainingItems.Count -gt 0) {
                    Set-Content -Path $QueueFile -Value $remainingItems -ErrorAction Stop
                } else {
                    Remove-Item -Path $QueueFile -Force -ErrorAction Stop
                }
            }
        }
    } catch {
        Write-ErrorLog "Error: Failed to process queue - $($_.Exception.Message)"
    }
}

function Build-HeartbeatPayload {
    $computerId = Get-ComputerUUID
    if (-not $computerId) {
        exit 1
    }
    
    $computerName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { "UNKNOWN" }
    $username = Get-CurrentUsername
    $uptime = Get-UptimeFormatted
    $idleTimeSeconds = Get-IdleTime
    $timestamp = [DateTime]::UtcNow.ToString("o")
    
    $payload = @{
        computerId = $computerId
        computerName = $computerName
        username = $username
        online = $true
        pcStatus = "on"
        pcUptime = $uptime
        idleTimeSeconds = $idleTimeSeconds
        timestamp = $timestamp
    }
    
    return ($payload | ConvertTo-Json -Compress)
}

#endregion

#region Main Execution

# Ensure data directory exists
try {
    $null = New-Item -ItemType Directory -Path $DataDirectory -Force -ErrorAction Stop
} catch {
    Write-ErrorLog "Error: Failed to create data directory - $($_.Exception.Message)"
    exit 1
}

# Get configuration from registry
$config = Get-ConfigFromRegistry
if (-not $config) {
    exit 1
}

# Build heartbeat payload
$payload = Build-HeartbeatPayload
if (-not $payload) {
    exit 1
}

# Check adaptive polling
$lastSendTime = Get-LastSendTime
$idleTimeSeconds = Get-IdleTime
$shouldSkip = Test-AdaptivePollingSkip -IdleTimeSeconds $idleTimeSeconds -LastSendTime $lastSendTime

if ($shouldSkip) {
    # Skip sending this heartbeat, but still try to process queue if we have connectivity
    Process-Queue -Config $config
    exit 0
}

# Try to send heartbeat
$success = Send-Heartbeat -Config $config -Payload $payload

if ($success) {
    Set-LastSendTime
    # Process queue after successful heartbeat
    Process-Queue -Config $config
} else {
    # Queue the failed heartbeat
    Add-ToQueue -JsonPayload $payload
}

#endregion

