#Requires -Version 5.1
# Main monitoring agent - sends system info to API every minute

#region Configuration
$RegistryPath = "HKLM:\SOFTWARE\MyMonitoringAgent"
$DataDirectory = "C:\ProgramData\MyAgent"
$QueueFile = Join-Path $DataDirectory "queue.jsonl"
$ErrorLogFile = Join-Path $DataDirectory "error.log"
$LastSendFile = Join-Path $DataDirectory "last_send.txt"
$MaxQueueSizeMB = 10
$BatchSize = 100  # send 100 queued items at a time
$AdaptivePollingThreshold = 600  # 10 minutes idle
$AdaptivePollingInterval = 300   # wait 5 minutes between sends when idle
#endregion

#region Helper Functions

function Write-ErrorLog {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $Message"
    try {
        Add-Content -Path $ErrorLogFile -Value $logMessage -ErrorAction Stop
    } catch {
        # log write failed, nothing we can do
    }
}

function Write-HeartbeatLog {
    # disabled to keep things fast
    param(
        [string]$Payload,
        [string]$Response = $null
    )
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
        # get system uptime in milliseconds
        $ticks = [Environment]::TickCount64
        if ($ticks -lt 0) {
            Write-ErrorLog "Error: TickCount64 returned negative value: $ticks"
            return "00:00:00"
        }
        
        $uptime = [TimeSpan]::FromMilliseconds($ticks)
        
        # show days if needed, otherwise just hours:minutes:seconds
        if ($uptime.Days -gt 0) {
            return "{0:00}:{1:00}:{2:00}:{3:00}" -f $uptime.Days, $uptime.Hours, $uptime.Minutes, $uptime.Seconds
        } else {
            return $uptime.ToString("HH\:mm\:ss")
        }
    } catch {
        Write-ErrorLog "Error: Failed to calculate uptime - $($_.Exception.Message)"
        return "00:00:00"
    }
}

function Get-IdleTime {
    # get time since last keyboard/mouse input
    # works when running as user or system account
    
    # check if the helper class is already loaded
    $typeExists = $false
    try {
        $null = [IdleTimeHelper]::GetIdleTimeSeconds()
        $typeExists = $true
    } catch {
        $typeExists = $false
    }
    
    if (-not $typeExists) {
        $csharpCode = @"
using System;
using System.Runtime.InteropServices;

public class IdleTimeHelper {
    [DllImport("user32.dll")]
    static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    
    [DllImport("kernel32.dll")]
    static extern uint WTSGetActiveConsoleSessionId();
    
    [DllImport("wtsapi32.dll", SetLastError = true)]
    static extern bool WTSQuerySessionInformation(IntPtr hServer, uint SessionId, WTS_INFO_CLASS WTSInfoClass, out IntPtr ppBuffer, out uint pBytesReturned);
    
    [DllImport("wtsapi32.dll")]
    static extern void WTSFreeMemory(IntPtr pMemory);
    
    [DllImport("wtsapi32.dll", SetLastError = true)]
    static extern bool WTSQueryUserToken(uint SessionId, out IntPtr phToken);
    
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);
    
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool DuplicateTokenEx(IntPtr hExistingToken, uint dwDesiredAccess, IntPtr lpTokenAttributes, int ImpersonationLevel, int TokenType, out IntPtr phNewToken);
    
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool SetThreadToken(ref IntPtr Thread, IntPtr Token);
    
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool ImpersonateLoggedOnUser(IntPtr hToken);
    
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool RevertToSelf();
    
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentThread();
    
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr hObject);
    
    [DllImport("kernel32.dll")]
    static extern uint GetLastError();
    
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO {
        public uint cbSize;
        public uint dwTime;
    }
    
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    static extern int RegOpenKeyEx(IntPtr hKey, string subKey, uint options, int samDesired, out IntPtr phkResult);
    
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern int RegQueryValueEx(IntPtr hKey, string lpValueName, IntPtr lpReserved, out uint lpType, IntPtr lpData, ref uint lpcbData);
    
    [DllImport("advapi32.dll")]
    static extern int RegCloseKey(IntPtr hKey);
    
    const int KEY_QUERY_VALUE = 0x0001;
    const int KEY_READ = 0x20019;
    static readonly IntPtr HKEY_USERS = new IntPtr(unchecked((int)0x80000003));
    
    enum WTS_INFO_CLASS {
        WTSInitialProgram = 0,
        WTSApplicationName = 1,
        WTSWorkingDirectory = 2,
        WTSOEMId = 3,
        WTSSessionId = 4,
        WTSUserName = 5,
        WTSWinStationName = 6,
        WTSDomainName = 7,
        WTSConnectState = 8,
        WTSClientBuildNumber = 9,
        WTSClientName = 10,
        WTSClientDirectory = 11,
        WTSClientProductId = 12,
        WTSClientHardwareId = 13,
        WTSClientAddress = 14,
        WTSClientDisplay = 15,
        WTSClientProtocolType = 16,
        WTSLogonTime = 18,
        WTSIncomingBytes = 19,
        WTSOutgoingBytes = 20,
        WTSIncomingFrames = 21,
        WTSOutgoingFrames = 22,
        WTSClientInfo = 23,
        WTSSessionInfo = 24,
        WTSSessionInfoEx = 25,
        WTSConfigInfo = 26,
        WTSValidationInfo = 27,
        WTSSessionAddressV4 = 28,
        WTSIsRemoteSession = 29
    }
    
    const uint TOKEN_QUERY = 0x0008;
    const uint TOKEN_DUPLICATE = 0x0002;
    const int SecurityImpersonation = 2;
    const int TokenImpersonation = 2;
    
    public static int GetIdleTimeSeconds() {
        // First, try GetLastInputInfo (works in user context)
        LASTINPUTINFO lastInput = new LASTINPUTINFO();
        lastInput.cbSize = (uint)Marshal.SizeOf(lastInput);
        
        bool getLastInputResult = GetLastInputInfo(ref lastInput);
        
        // Check if GetLastInputInfo succeeded AND returned valid data (dwTime != 0)
        // When running as SYSTEM, GetLastInputInfo may return TRUE but with dwTime=0 (invalid)
        if (getLastInputResult && lastInput.dwTime != 0) {
            // Success - calculate idle time
            // Use TickCount (32-bit) and handle wraparound for compatibility with older .NET versions
            uint currentTicks = (uint)Environment.TickCount;
            uint lastInputTicks32 = lastInput.dwTime;
            
            uint idleMs;
            if (currentTicks >= lastInputTicks32) {
                idleMs = currentTicks - lastInputTicks32;
            } else {
                // Handle wraparound (occurs every ~49.7 days)
                idleMs = (uint.MaxValue - lastInputTicks32) + currentTicks + 1;
            }
            
            int result = (int)(idleMs / 1000);
            return result;
        }
        
        // GetLastInputInfo failed - try to impersonate active session and retry
        // This allows us to call GetLastInputInfo in the context of the active user session
        try {
            uint activeSessionId = WTSGetActiveConsoleSessionId();
            
            if (activeSessionId == 0xFFFFFFFF || activeSessionId == 0) {
                // nobody logged in
                return 0;
            }
            
            // get the logged-in user's token so we can check their idle time
            IntPtr hSessionToken = IntPtr.Zero;
            IntPtr hDupToken = IntPtr.Zero;
            IntPtr hThread = GetCurrentThread();
            
            try {
                // Get the user token for the active session
                bool wtsQueryResult = WTSQueryUserToken(activeSessionId, out hSessionToken);
                
                if (wtsQueryResult) {
                    // make a copy of the token
                    bool dupTokenResult = DuplicateTokenEx(hSessionToken, TOKEN_QUERY | TOKEN_DUPLICATE, IntPtr.Zero, SecurityImpersonation, TokenImpersonation, out hDupToken);
                    
                    if (dupTokenResult) {
                        // switch to the user's context
                        bool impersonateResult = ImpersonateLoggedOnUser(hDupToken);
                        
                        if (impersonateResult) {
                            // try getting idle time again as the user
                            LASTINPUTINFO lastInput2 = new LASTINPUTINFO();
                            lastInput2.cbSize = (uint)Marshal.SizeOf(lastInput2);
                            
                            bool getLastInput2Result = GetLastInputInfo(ref lastInput2);
                            
                            // if it worked this time
                            if (getLastInput2Result && lastInput2.dwTime != 0) {
                                // calculate idle time
                                uint currentTicks = (uint)Environment.TickCount;
                                uint lastInputTicks32 = lastInput2.dwTime;
                                
                                uint idleMs;
                                if (currentTicks >= lastInputTicks32) {
                                    idleMs = currentTicks - lastInputTicks32;
                                } else {
                                    // handle wraparound
                                    idleMs = (uint.MaxValue - lastInputTicks32) + currentTicks + 1;
                                }
                                
                                // switch back to our original context
                                RevertToSelf();
                                
                                int result = (int)(idleMs / 1000);
                                return result;
                            }
                            
                            // switch back
                            RevertToSelf();
                        }
                    }
                }
            } finally {
                if (hDupToken != IntPtr.Zero) CloseHandle(hDupToken);
                if (hSessionToken != IntPtr.Zero) CloseHandle(hSessionToken);
            }
        } catch {
            // couldn't get idle time, return 0
        }
        
        return 0;
    }
}
"@
        
        try {
            Add-Type -TypeDefinition $csharpCode -ErrorAction Stop
        } catch {
            Write-ErrorLog "Error: Failed to compile IdleTimeHelper C# code - $($_.Exception.Message). This may prevent idle time detection."
            return 0
        }
    }
    
    try {
        $idleSeconds = [IdleTimeHelper]::GetIdleTimeSeconds()
        
        return $idleSeconds
    } catch {
        Write-ErrorLog "Error: Failed to get idle time - $($_.Exception.Message)"
        return 0
    }
}

function Get-CurrentUsername {
    try {
        $username = (Get-CimInstance Win32_ComputerSystem).UserName
        if (-not $username) {
            $username = if ($env:USERNAME) { $env:USERNAME } else { "SYSTEM" }
        }
        # remove domain part if username has one
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
                    # read the timestamp
                    try {
                        $timestamp = [DateTime]::Parse($trimmed, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
                        return $timestamp
                    } catch {
                        # try simpler format
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
        # create data directory if it doesn't exist
        $null = New-Item -ItemType Directory -Path $DataDirectory -Force -ErrorAction Stop
        
        # if queue file is getting too large, trim old items
        if (Test-Path $QueueFile) {
            $fileInfo = Get-Item $QueueFile
            $sizeMB = $fileInfo.Length / 1MB
            
            if ($sizeMB -gt $MaxQueueSizeMB) {
                # keep only the most recent items
                $allLines = @(Get-Content $QueueFile)
                $allLines = $allLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                $maxLines = [Math]::Floor(($MaxQueueSizeMB * 1MB) / 500)  # ~500 bytes per line
                $linesToKeep = $allLines | Select-Object -Last $maxLines
                
                # write back the trimmed queue
                if ($linesToKeep.Count -gt 0) {
                    Set-Content -Path $QueueFile -Value $linesToKeep -ErrorAction Stop
                } else {
                    Remove-Item -Path $QueueFile -Force -ErrorAction Stop
                }
            }
        }
        
        # add this heartbeat to the queue
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
        
        # log the response
        $responseStr = if ($response) { ($response | ConvertTo-Json -Compress) } else { "OK" }
        Write-HeartbeatLog -Payload $Payload -Response $responseStr
        
        return $true
    } catch {
        Write-ErrorLog "API Error: Failed to send heartbeat - $($_.Exception.Message)"
        return $false
    }
}

function Invoke-Queue {
    param([hashtable]$Config)
    
    if (-not (Test-Path $QueueFile)) {
        return
    }
    
    try {
        $queuedItems = @(Get-Content $QueueFile)
        # ignore empty lines in queue file
        $queuedItems = $queuedItems | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        
        if ($queuedItems.Count -eq 0) {
            Remove-Item -Path $QueueFile -Force -ErrorAction Stop
            return
        }
        
        $headers = @{
            "Content-Type" = "application/json"
            "X-API-KEY" = $Config.ApiKey
        }
        
        $processedCount = 0
        $failedItems = @()
        
        # send items in batches to avoid overloading
        for ($i = 0; $i -lt $queuedItems.Count; $i += $BatchSize) {
            $batch = $queuedItems[$i..([Math]::Min($i + $BatchSize - 1, $queuedItems.Count - 1))]
            
            foreach ($item in $batch) {
                try {
                    $response = Invoke-RestMethod -Uri $Config.ApiUrl -Method Post -Headers $headers -Body $item -ContentType "application/json" -ErrorAction Stop
                    $processedCount++
                    
                    # log successful send
                    $responseStr = if ($response) { ($response | ConvertTo-Json -Compress) } else { "OK" }
                    Write-HeartbeatLog -Payload $item -Response $responseStr
                } catch {
                    Write-ErrorLog "Queue Error: Failed to send queued item - $($_.Exception.Message)"
                    $failedItems += $item
                }
            }
        }
        
        # save only the items that failed
        if ($failedItems.Count -eq 0) {
            # everything sent, delete queue file
            Remove-Item -Path $QueueFile -Force -ErrorAction Stop
        } else {
            # save failed items back to queue
            if ($failedItems.Count -lt $queuedItems.Count) {
                Set-Content -Path $QueueFile -Value $failedItems -ErrorAction Stop
            }
            # if everything failed, queue file stays as-is
        }
    } catch {
        Write-ErrorLog "Error: Failed to process queue - $($_.Exception.Message)"
    }
}

function New-HeartbeatPayload {
    param([int]$IdleTimeSeconds)
    
    $computerId = Get-ComputerUUID
    if (-not $computerId) {
        exit 1
    }
    
    $computerName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { "UNKNOWN" }
    $username = Get-CurrentUsername
    $uptime = Get-UptimeFormatted
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

# make sure data directory exists
try {
    $null = New-Item -ItemType Directory -Path $DataDirectory -Force -ErrorAction Stop
} catch {
    Write-ErrorLog "Error: Failed to create data directory - $($_.Exception.Message)"
    exit 1
}

# get API URL and key from registry
$config = Get-ConfigFromRegistry
if (-not $config) {
    exit 1
}

# check how long since user last touched keyboard/mouse
$idleTimeSeconds = Get-IdleTime

# skip sending if computer is idle (adaptive polling)
$lastSendTime = Get-LastSendTime
$shouldSkip = Test-AdaptivePollingSkip -IdleTimeSeconds $idleTimeSeconds -LastSendTime $lastSendTime

if ($shouldSkip) {
    # don't send new heartbeat, but try to send queued items
    Invoke-Queue -Config $config
    exit 0
}

# gather system info and build JSON payload
$payload = New-HeartbeatPayload -IdleTimeSeconds $idleTimeSeconds
if (-not $payload) {
    exit 1
}

# send heartbeat to API
$success = Send-Heartbeat -Config $config -Payload $payload

if ($success) {
    Set-LastSendTime
    # send any items waiting in queue
    Invoke-Queue -Config $config
} else {
    # save to queue for retry later
    Add-ToQueue -JsonPayload $payload
}

#endregion

