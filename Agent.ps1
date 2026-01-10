#Requires -Version 5.1
# Monitoring agent - sends heartbeat data every minute

#region Configuration
$RegistryPath = "HKLM:\SOFTWARE\MyMonitoringAgent"
$DataDirectory = "C:\ProgramData\MyAgent"
$QueueFile = Join-Path $DataDirectory "queue.jsonl"
$ErrorLogFile = Join-Path $DataDirectory "error.log"
$HeartbeatLogFile = Join-Path $DataDirectory "heartbeat.log"
$LastSendFile = Join-Path $DataDirectory "last_send.txt"
$MaxQueueSizeMB = 10
$MaxHeartbeatLogSizeMB = 10  # log rotates when it hits this size
$BatchSize = 50
$AdaptivePollingThreshold = 600  # 10 minutes
$AdaptivePollingInterval = 300   # 5 minutes
#endregion

#region Helper Functions

function Write-ErrorLog {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $Message"
    try {
        Add-Content -Path $ErrorLogFile -Value $LogMessage -ErrorAction Stop
    } catch {
        # can't write the log? nothing we can do
    }
}

function Write-HeartbeatLog {
    param(
        [string]$Payload,
        [string]$Response = $null
    )
    
    try {
        # make sure directory exists
        $null = New-Item -ItemType Directory -Path $DataDirectory -Force -ErrorAction Stop
        
        # rotate log if it's too big
        if (Test-Path $HeartbeatLogFile) {
            $fileInfo = Get-Item $HeartbeatLogFile
            $sizeMB = $fileInfo.Length / 1MB
            
            if ($sizeMB -gt $MaxHeartbeatLogSizeMB) {
                # rename current log to .old
                $oldLogFile = "$HeartbeatLogFile.old"
                if (Test-Path $oldLogFile) {
                    Remove-Item -Path $oldLogFile -Force -ErrorAction SilentlyContinue
                }
                Move-Item -Path $HeartbeatLogFile -Destination $oldLogFile -Force -ErrorAction Stop
            }
        }
        
        # parse payload so we can log it nicely
        $payloadObj = $Payload | ConvertFrom-Json
        
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logEntry = @"
[$timestamp] Heartbeat Sent Successfully
  Computer ID: $($payloadObj.computerId)
  Computer Name: $($payloadObj.computerName)
  Username: $($payloadObj.username)
  Uptime: $($payloadObj.pcUptime)
  Idle Time: $($payloadObj.idleTimeSeconds) seconds
  Timestamp: $($payloadObj.timestamp)
$(if ($Response) { "  API Response: $Response" })
  Full Payload: $Payload
---
"@
        
        Add-Content -Path $HeartbeatLogFile -Value $logEntry -ErrorAction Stop
    } catch {
        # failed to write heartbeat log - not critical
        Write-ErrorLog "Warning: Failed to write heartbeat log - $($_.Exception.Message)"
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
        # get boot time from WMI - works in any context
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $bootTime = $os.LastBootUpTime
        
        if (-not $bootTime) {
            Write-ErrorLog "Warning: LastBootUpTime is null, falling back to TickCount64"
            # fallback if WMI doesn't work
            $ticks = [Environment]::TickCount64
            if ($ticks -le 0) {
                Write-ErrorLog "Error: TickCount64 returned $ticks"
                return "00:00:00"
            }
            $uptime = [TimeSpan]::FromMilliseconds($ticks)
        } else {
            # normal path - calculate from boot time
            $now = Get-Date
            $uptime = $now - $bootTime
        }
        
        # format uptime nicely
        if ($uptime.Days -gt 0) {
            return "{0:00}:{1:00}:{2:00}:{3:00}" -f $uptime.Days, $uptime.Hours, $uptime.Minutes, $uptime.Seconds
        } else {
            return $uptime.ToString("hh\:mm\:ss")
        }
    } catch {
        Write-ErrorLog "Error: Failed to calculate uptime - $($_.Exception.Message). StackTrace: $($_.ScriptStackTrace)"
        return "00:00:00"
    }
}

function Get-IdleTime {
    # call Windows API to get idle time
    # works in both SYSTEM and user contexts
    
    # check if we already loaded this
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
        // #region agent log
        try {
            long ts = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalMilliseconds;
            System.IO.File.AppendAllText(@"c:\Users\samsa\OneDrive\Desktop\idlewinapi2\.cursor\debug.log", 
                "{\"sessionId\":\"debug-session\",\"runId\":\"run1\",\"hypothesisId\":\"A\",\"location\":\"IdleTimeHelper.GetIdleTimeSeconds:243\",\"message\":\"Function entry\",\"data\":{\"timestamp\":" + ts + "},\"timestamp\":" + ts + "}\n");
        } catch {}
        // #endregion
        
        // First, try GetLastInputInfo (works in user context)
        LASTINPUTINFO lastInput = new LASTINPUTINFO();
        lastInput.cbSize = (uint)Marshal.SizeOf(lastInput);
        
        bool getLastInputResult = GetLastInputInfo(ref lastInput);
        // #region agent log
        try {
            long ts = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalMilliseconds;
            uint ct = (uint)Environment.TickCount;
            System.IO.File.AppendAllText(@"c:\Users\samsa\OneDrive\Desktop\idlewinapi2\.cursor\debug.log", 
                "{\"sessionId\":\"debug-session\",\"runId\":\"run1\",\"hypothesisId\":\"A\",\"location\":\"IdleTimeHelper.GetIdleTimeSeconds:248\",\"message\":\"GetLastInputInfo first attempt\",\"data\":{\"success\":" + getLastInputResult.ToString().ToLower() + ",\"lastInputTicks\":" + lastInput.dwTime + ",\"currentTicks\":" + ct + ",\"timestamp\":" + ts + "},\"timestamp\":" + ts + "}\n");
        } catch {}
        // #endregion
        
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
            // #region agent log
            try {
                long ts = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalMilliseconds;
                System.IO.File.AppendAllText(@"c:\Users\samsa\OneDrive\Desktop\idlewinapi2\.cursor\debug.log", 
                    "{\"sessionId\":\"debug-session\",\"runId\":\"run1\",\"hypothesisId\":\"A\",\"location\":\"IdleTimeHelper.GetIdleTimeSeconds:262\",\"message\":\"Direct GetLastInputInfo success path\",\"data\":{\"currentTicks\":" + currentTicks + ",\"lastInputTicks32\":" + lastInputTicks32 + ",\"idleMs\":" + idleMs + ",\"resultSeconds\":" + result + ",\"timestamp\":" + ts + "},\"timestamp\":" + ts + "}\n");
            } catch {}
            // #endregion
            return result;
        }
        
        // #region agent log
        try {
            long ts = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalMilliseconds;
            System.IO.File.AppendAllText(@"c:\Users\samsa\OneDrive\Desktop\idlewinapi2\.cursor\debug.log", 
                "{\"sessionId\":\"debug-session\",\"runId\":\"run1\",\"hypothesisId\":\"A\",\"location\":\"IdleTimeHelper.GetIdleTimeSeconds:267\",\"message\":\"GetLastInputInfo failed or returned invalid dwTime=0, trying impersonation\",\"data\":{\"getLastInputResult\":" + getLastInputResult.ToString().ToLower() + ",\"dwTime\":" + lastInput.dwTime + ",\"timestamp\":" + ts + "},\"timestamp\":" + ts + "}\n");
        } catch {}
        // #endregion
        
        // GetLastInputInfo failed - try to impersonate active session and retry
        // This allows us to call GetLastInputInfo in the context of the active user session
        try {
            uint activeSessionId = WTSGetActiveConsoleSessionId();
            // #region agent log
            try {
                long ts = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalMilliseconds;
                bool invalid = (activeSessionId == 0xFFFFFFFF || activeSessionId == 0);
                System.IO.File.AppendAllText(@"c:\Users\samsa\OneDrive\Desktop\idlewinapi2\.cursor\debug.log", 
                    "{\"sessionId\":\"debug-session\",\"runId\":\"run1\",\"hypothesisId\":\"B\",\"location\":\"IdleTimeHelper.GetIdleTimeSeconds:268\",\"message\":\"WTSGetActiveConsoleSessionId result\",\"data\":{\"activeSessionId\":\"" + activeSessionId + "\",\"isInvalid\":" + invalid.ToString().ToLower() + ",\"timestamp\":" + ts + "},\"timestamp\":" + ts + "}\n");
            } catch {}
            // #endregion
            
            if (activeSessionId == 0xFFFFFFFF || activeSessionId == 0) {
                // No active console session
                // #region agent log
                try {
                    long ts = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalMilliseconds;
                    System.IO.File.AppendAllText(@"c:\Users\samsa\OneDrive\Desktop\idlewinapi2\.cursor\debug.log", 
                        "{\"sessionId\":\"debug-session\",\"runId\":\"run1\",\"hypothesisId\":\"B\",\"location\":\"IdleTimeHelper.GetIdleTimeSeconds:271\",\"message\":\"No active console session - returning 0\",\"data\":{\"activeSessionId\":\"" + activeSessionId + "\",\"timestamp\":" + ts + "},\"timestamp\":" + ts + "}\n");
                } catch {}
                // #endregion
                return 0;
            }
            
            // Try to get the session's user token and impersonate it
            IntPtr hSessionToken = IntPtr.Zero;
            IntPtr hDupToken = IntPtr.Zero;
            IntPtr hThread = GetCurrentThread();
            
            try {
                // Get the user token for the active session
                bool wtsQueryResult = WTSQueryUserToken(activeSessionId, out hSessionToken);
                // #region agent log
                try {
                    long ts = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalMilliseconds;
                    int lastErr = Marshal.GetLastWin32Error();
                    System.IO.File.AppendAllText(@"c:\Users\samsa\OneDrive\Desktop\idlewinapi2\.cursor\debug.log", 
                        "{\"sessionId\":\"debug-session\",\"runId\":\"run1\",\"hypothesisId\":\"C\",\"location\":\"IdleTimeHelper.GetIdleTimeSeconds:281\",\"message\":\"WTSQueryUserToken result\",\"data\":{\"success\":" + wtsQueryResult.ToString().ToLower() + ",\"sessionId\":\"" + activeSessionId + "\",\"tokenHandle\":\"" + hSessionToken.ToString() + "\",\"lastError\":" + lastErr + ",\"timestamp\":" + ts + "},\"timestamp\":" + ts + "}\n");
                } catch {}
                // #endregion
                
                if (wtsQueryResult) {
                    // Duplicate the token for impersonation
                    bool dupTokenResult = DuplicateTokenEx(hSessionToken, TOKEN_QUERY | TOKEN_DUPLICATE, IntPtr.Zero, SecurityImpersonation, TokenImpersonation, out hDupToken);
                    // #region agent log
                    try {
                        long ts = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalMilliseconds;
                        int lastErr = Marshal.GetLastWin32Error();
                        System.IO.File.AppendAllText(@"c:\Users\samsa\OneDrive\Desktop\idlewinapi2\.cursor\debug.log", 
                            "{\"sessionId\":\"debug-session\",\"runId\":\"run1\",\"hypothesisId\":\"D\",\"location\":\"IdleTimeHelper.GetIdleTimeSeconds:283\",\"message\":\"DuplicateTokenEx result\",\"data\":{\"success\":" + dupTokenResult.ToString().ToLower() + ",\"dupTokenHandle\":\"" + hDupToken.ToString() + "\",\"lastError\":" + lastErr + ",\"timestamp\":" + ts + "},\"timestamp\":" + ts + "}\n");
                    } catch {}
                    // #endregion
                    
                    if (dupTokenResult) {
                        // Try ImpersonateLoggedOnUser instead of SetThreadToken (more reliable for SYSTEM)
                        bool impersonateResult = ImpersonateLoggedOnUser(hDupToken);
                        // #region agent log
                        try {
                            long ts = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalMilliseconds;
                            int lastErr = Marshal.GetLastWin32Error();
                            System.IO.File.AppendAllText(@"c:\Users\samsa\OneDrive\Desktop\idlewinapi2\.cursor\debug.log", 
                                "{\"sessionId\":\"debug-session\",\"runId\":\"run1\",\"hypothesisId\":\"D\",\"location\":\"IdleTimeHelper.GetIdleTimeSeconds:285\",\"message\":\"ImpersonateLoggedOnUser result\",\"data\":{\"success\":" + impersonateResult.ToString().ToLower() + ",\"lastError\":" + lastErr + ",\"timestamp\":" + ts + "},\"timestamp\":" + ts + "}\n");
                        } catch {}
                        // #endregion
                        
                        if (impersonateResult) {
                            // Now try GetLastInputInfo again in the impersonated context
                            LASTINPUTINFO lastInput2 = new LASTINPUTINFO();
                            lastInput2.cbSize = (uint)Marshal.SizeOf(lastInput2);
                            
                            bool getLastInput2Result = GetLastInputInfo(ref lastInput2);
                            // #region agent log
                            try {
                                long ts = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalMilliseconds;
                                uint ct2 = (uint)Environment.TickCount;
                                System.IO.File.AppendAllText(@"c:\Users\samsa\OneDrive\Desktop\idlewinapi2\.cursor\debug.log", 
                                    "{\"sessionId\":\"debug-session\",\"runId\":\"run1\",\"hypothesisId\":\"E\",\"location\":\"IdleTimeHelper.GetIdleTimeSeconds:290\",\"message\":\"GetLastInputInfo after impersonation\",\"data\":{\"success\":" + getLastInput2Result.ToString().ToLower() + ",\"lastInputTicks\":" + lastInput2.dwTime + ",\"currentTicks\":" + ct2 + ",\"timestamp\":" + ts + "},\"timestamp\":" + ts + "}\n");
                            } catch {}
                            // #endregion
                            
                            // Check if GetLastInputInfo succeeded AND returned valid data (dwTime != 0)
                            if (getLastInput2Result && lastInput2.dwTime != 0) {
                                // Success - calculate idle time
                                // Use TickCount (32-bit) and handle wraparound
                                uint currentTicks = (uint)Environment.TickCount;
                                uint lastInputTicks32 = lastInput2.dwTime;
                                
                                uint idleMs;
                                if (currentTicks >= lastInputTicks32) {
                                    idleMs = currentTicks - lastInputTicks32;
                                } else {
                                    // Handle wraparound (occurs every ~49.7 days)
                                    idleMs = (uint.MaxValue - lastInputTicks32) + currentTicks + 1;
                                }
                                
                                // Revert impersonation
                                RevertToSelf();
                                
                                int result = (int)(idleMs / 1000);
                                // #region agent log
                                try {
                                    long ts = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalMilliseconds;
                                    System.IO.File.AppendAllText(@"c:\Users\samsa\OneDrive\Desktop\idlewinapi2\.cursor\debug.log", 
                                        "{\"sessionId\":\"debug-session\",\"runId\":\"run1\",\"hypothesisId\":\"E\",\"location\":\"IdleTimeHelper.GetIdleTimeSeconds:307\",\"message\":\"Impersonation path success\",\"data\":{\"currentTicks\":" + currentTicks + ",\"lastInputTicks32\":" + lastInputTicks32 + ",\"idleMs\":" + idleMs + ",\"resultSeconds\":" + result + ",\"timestamp\":" + ts + "},\"timestamp\":" + ts + "}\n");
                                } catch {}
                                // #endregion
                                return result;
                            }
                            
                            // Revert impersonation
                            RevertToSelf();
                            // #region agent log
                            try {
                                long ts = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalMilliseconds;
                                System.IO.File.AppendAllText(@"c:\Users\samsa\OneDrive\Desktop\idlewinapi2\.cursor\debug.log", 
                                    "{\"sessionId\":\"debug-session\",\"runId\":\"run1\",\"hypothesisId\":\"E\",\"location\":\"IdleTimeHelper.GetIdleTimeSeconds:311\",\"message\":\"GetLastInputInfo failed after impersonation\",\"data\":{\"timestamp\":" + ts + "},\"timestamp\":" + ts + "}\n");
                            } catch {}
                            // #endregion
                        } else {
                            // #region agent log
                            try {
                                long ts = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalMilliseconds;
                                int lastErr = Marshal.GetLastWin32Error();
                                System.IO.File.AppendAllText(@"c:\Users\samsa\OneDrive\Desktop\idlewinapi2\.cursor\debug.log", 
                                    "{\"sessionId\":\"debug-session\",\"runId\":\"run1\",\"hypothesisId\":\"D\",\"location\":\"IdleTimeHelper.GetIdleTimeSeconds:313\",\"message\":\"ImpersonateLoggedOnUser failed\",\"data\":{\"lastError\":" + lastErr + ",\"timestamp\":" + ts + "},\"timestamp\":" + ts + "}\n");
                            } catch {}
                            // #endregion
                        }
                    }
                }
            } finally {
                if (hDupToken != IntPtr.Zero) CloseHandle(hDupToken);
                if (hSessionToken != IntPtr.Zero) CloseHandle(hSessionToken);
            }
        } catch (Exception ex) {
            // Impersonation failed, return 0
            // #region agent log
            try {
                long ts = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalMilliseconds;
                string exMsg = ex.Message.Replace("\"", "\\\"").Replace("\n", "\\n").Replace("\r", "");
                string exStack = ex.StackTrace != null ? ex.StackTrace.Replace("\"", "\\\"").Replace("\n", "\\n").Replace("\r", "") : "";
                System.IO.File.AppendAllText(@"c:\Users\samsa\OneDrive\Desktop\idlewinapi2\.cursor\debug.log", 
                    "{\"sessionId\":\"debug-session\",\"runId\":\"run1\",\"hypothesisId\":\"G\",\"location\":\"IdleTimeHelper.GetIdleTimeSeconds:319\",\"message\":\"Exception caught\",\"data\":{\"exceptionType\":\"" + ex.GetType().Name + "\",\"message\":\"" + exMsg + "\",\"stackTrace\":\"" + exStack + "\",\"timestamp\":" + ts + "},\"timestamp\":" + ts + "}\n");
            } catch {}
            // #endregion
        }
        
        // #region agent log
        try {
            long ts = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalMilliseconds;
            System.IO.File.AppendAllText(@"c:\Users\samsa\OneDrive\Desktop\idlewinapi2\.cursor\debug.log", 
                "{\"sessionId\":\"debug-session\",\"runId\":\"run1\",\"hypothesisId\":\"A\",\"location\":\"IdleTimeHelper.GetIdleTimeSeconds:323\",\"message\":\"Returning 0 - all paths failed\",\"data\":{\"timestamp\":" + ts + "},\"timestamp\":" + ts + "}\n");
        } catch {}
        // #endregion
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
        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        # #region agent log
        try {
            $logData = @{
                sessionId = "debug-session"
                runId = "run1"
                hypothesisId = "A"
                location = "Get-IdleTime:340"
                message = "Calling GetIdleTimeSeconds"
                data = @{
                    currentUser = $currentUser
                    timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                }
                timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            }
            $logJson = $logData | ConvertTo-Json -Compress
            Add-Content -Path "c:\Users\samsa\OneDrive\Desktop\idlewinapi2\.cursor\debug.log" -Value $logJson -ErrorAction SilentlyContinue
        } catch {}
        # #endregion
        
        $idleSeconds = [IdleTimeHelper]::GetIdleTimeSeconds()
        
        # #region agent log
        try {
            $logData = @{
                sessionId = "debug-session"
                runId = "run1"
                hypothesisId = "A"
                location = "Get-IdleTime:355"
                message = "GetIdleTimeSeconds returned"
                data = @{
                    idleSeconds = $idleSeconds
                    currentUser = $currentUser
                    timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                }
                timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            }
            $logJson = $logData | ConvertTo-Json -Compress
            Add-Content -Path "c:\Users\samsa\OneDrive\Desktop\idlewinapi2\.cursor\debug.log" -Value $logJson -ErrorAction SilentlyContinue
        } catch {}
        # #endregion
        
        # Log diagnostic information
        if ($idleSeconds -eq 0) {
            if ($currentUser -match "SYSTEM|LOCAL SERVICE|NETWORK SERVICE") {
                Write-ErrorLog "Info: Idle time is 0 while running as $currentUser. This may indicate no active user session or session is locked."
            } else {
                Write-ErrorLog "Info: Idle time is 0 for user $currentUser. User may have just logged in or session may be locked."
            }
        } else {
            # Successfully got idle time
            Write-ErrorLog "Info: Successfully retrieved idle time: $idleSeconds seconds (running as $currentUser)"
        }
        
        return $idleSeconds
    } catch {
        # #region agent log
        try {
            $logData = @{
                sessionId = "debug-session"
                runId = "run1"
                hypothesisId = "G"
                location = "Get-IdleTime:378"
                message = "Exception in Get-IdleTime"
                data = @{
                    exceptionMessage = $_.Exception.Message
                    stackTrace = $_.ScriptStackTrace
                    timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                }
                timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            }
            $logJson = $logData | ConvertTo-Json -Compress
            Add-Content -Path "c:\Users\samsa\OneDrive\Desktop\idlewinapi2\.cursor\debug.log" -Value $logJson -ErrorAction SilentlyContinue
        } catch {}
        # #endregion
        Write-ErrorLog "Error: Failed to get idle time - $($_.Exception.Message). StackTrace: $($_.ScriptStackTrace)"
        return 0
    }
}

function Get-CurrentUsername {
    try {
        $username = (Get-CimInstance Win32_ComputerSystem).UserName
        if (-not $username) {
            $username = if ($env:USERNAME) { $env:USERNAME } else { "SYSTEM" }
        }
        # strip domain if present
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
                    # parse the timestamp
                    try {
                        $timestamp = [DateTime]::Parse($trimmed, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
                        return $timestamp
                    } catch {
                        # try basic parsing
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
        # make sure directory exists
        $null = New-Item -ItemType Directory -Path $DataDirectory -Force -ErrorAction Stop
        
        # check if queue is too big
        if (Test-Path $QueueFile) {
            $fileInfo = Get-Item $QueueFile
            $sizeMB = $fileInfo.Length / 1MB
            
            if ($sizeMB -gt $MaxQueueSizeMB) {
                # trim old entries to keep queue manageable
                $allLines = @(Get-Content $QueueFile)
                $allLines = $allLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                $maxLines = [Math]::Floor(($MaxQueueSizeMB * 1MB) / 500)  # ~500 bytes per line
                $linesToKeep = $allLines | Select-Object -Last $maxLines
                
                # save the trimmed queue
                if ($linesToKeep.Count -gt 0) {
                    Set-Content -Path $QueueFile -Value $linesToKeep -ErrorAction Stop
                } else {
                    Remove-Item -Path $QueueFile -Force -ErrorAction Stop
                }
            }
        }
        
        # add new item to queue
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
        
        # log it
        $responseStr = if ($response) { ($response | ConvertTo-Json -Compress) } else { "OK" }
        Write-HeartbeatLog -Payload $Payload -Response $responseStr
        
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
        # skip empty lines
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
        
        # send queued items in batches
        for ($i = 0; $i -lt $queuedItems.Count; $i += $BatchSize) {
            $batch = $queuedItems[$i..([Math]::Min($i + $BatchSize - 1, $queuedItems.Count - 1))]
            
            foreach ($item in $batch) {
                try {
                    $response = Invoke-RestMethod -Uri $Config.ApiUrl -Method Post -Headers $headers -Body $item -ContentType "application/json" -ErrorAction Stop
                    $processedCount++
                    
                    # log queued item sent
                    $responseStr = if ($response) { ($response | ConvertTo-Json -Compress) } else { "OK" }
                    Write-HeartbeatLog -Payload $item -Response $responseStr
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
        
        # clear queue if everything sent
        if ($allSucceeded -and $processedCount -eq $queuedItems.Count) {
            Remove-Item -Path $QueueFile -Force -ErrorAction Stop
        } else {
            # remove items that sent successfully
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

# create data directory if needed
try {
    $null = New-Item -ItemType Directory -Path $DataDirectory -Force -ErrorAction Stop
} catch {
    Write-ErrorLog "Error: Failed to create data directory - $($_.Exception.Message)"
    exit 1
}

# load config
$config = Get-ConfigFromRegistry
if (-not $config) {
    exit 1
}

# build the payload
$payload = Build-HeartbeatPayload
if (-not $payload) {
    exit 1
}

# check if we should skip this beat
$lastSendTime = Get-LastSendTime
$idleTimeSeconds = Get-IdleTime
$shouldSkip = Test-AdaptivePollingSkip -IdleTimeSeconds $idleTimeSeconds -LastSendTime $lastSendTime

if ($shouldSkip) {
    # skip heartbeat but process queue if possible
    Process-Queue -Config $config
    exit 0
}

# send the heartbeat
$success = Send-Heartbeat -Config $config -Payload $payload

if ($success) {
    Set-LastSendTime
    # process any queued items
    Process-Queue -Config $config
} else {
    # save for later
    Add-ToQueue -JsonPayload $payload
}

#endregion

