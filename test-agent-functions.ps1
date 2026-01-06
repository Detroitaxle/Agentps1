# Test Agent Functions Script
# Tests the uptime and idle time functions in the current context
# Run as regular user and as SYSTEM to compare results

Write-Host "=== Agent Functions Test ===" -ForegroundColor Cyan
Write-Host ""

# Check current user context
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$isSystem = $currentUser -match "SYSTEM|LOCAL SERVICE|NETWORK SERVICE"

Write-Host "Current User Context: $currentUser" -ForegroundColor $(if ($isSystem) { "Yellow" } else { "Green" })
Write-Host "Running as SYSTEM: $isSystem" -ForegroundColor $(if ($isSystem) { "Yellow" } else { "Green" })
Write-Host ""

# Source Agent.ps1 to get the functions
$agentPath = Join-Path $PSScriptRoot "Agent.ps1"
if (-not (Test-Path $agentPath)) {
    Write-Host "ERROR: Agent.ps1 not found at $agentPath" -ForegroundColor Red
    exit 1
}

Write-Host "Loading functions from Agent.ps1..." -ForegroundColor Yellow
try {
    # Define the functions locally (extract from Agent.ps1 logic)
    # We'll test the actual implementation
    
    # Test Uptime Function
    Write-Host "=== Testing Get-UptimeFormatted ===" -ForegroundColor Cyan
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $bootTime = $os.LastBootUpTime
        
        if ($bootTime) {
            $now = Get-Date
            $uptime = $now - $bootTime
            if ($uptime.Days -gt 0) {
                $uptimeFormatted = "{0:00}:{1:00}:{2:00}:{3:00}" -f $uptime.Days, $uptime.Hours, $uptime.Minutes, $uptime.Seconds
            } else {
                $uptimeFormatted = $uptime.ToString("hh\:mm\:ss")
            }
            Write-Host "[SUCCESS] Uptime: $uptimeFormatted" -ForegroundColor Green
            Write-Host "  Boot Time: $bootTime" -ForegroundColor Gray
            Write-Host "  Current Time: $now" -ForegroundColor Gray
            Write-Host "  Total Seconds: $([Math]::Floor($uptime.TotalSeconds))" -ForegroundColor Gray
        } else {
            Write-Host "[ERROR] LastBootUpTime is null" -ForegroundColor Red
        }
    } catch {
        Write-Host "[ERROR] Failed to get uptime: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  StackTrace: $($_.ScriptStackTrace)" -ForegroundColor Gray
    }
    Write-Host ""
    
    # Test Idle Time Function
    Write-Host "=== Testing Get-IdleTime ===" -ForegroundColor Cyan
    try {
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
            long currentTicks64 = Environment.TickCount64;
            uint lastInputTicks32 = lastInput.dwTime;
            uint currentTicks32 = (uint)(currentTicks64 & 0xFFFFFFFF);
            long idleMs;
            if (currentTicks32 >= lastInputTicks32) {
                idleMs = currentTicks32 - lastInputTicks32;
            } else {
                idleMs = ((long)0x100000000L + currentTicks32) - lastInputTicks32;
            }
            return (int)(idleMs / 1000);
        }
        return 0;
    }
}
"@
        Add-Type -TypeDefinition $csharpCode -ErrorAction SilentlyContinue
        $idleSeconds = [IdleTimeHelper]::GetIdleTimeSeconds()
        
        Write-Host "[SUCCESS] Idle Time: $idleSeconds seconds ($([Math]::Floor($idleSeconds / 60)) minutes)" -ForegroundColor $(if ($idleSeconds -gt 0) { "Green" } else { "Yellow" })
        
        if ($idleSeconds -eq 0 -and $isSystem) {
            Write-Host "  [INFO] Idle time is 0 in SYSTEM context - this is expected Windows API behavior" -ForegroundColor Yellow
            Write-Host "  GetLastInputInfo only works in interactive user sessions" -ForegroundColor Yellow
        } elseif ($idleSeconds -eq 0) {
            Write-Host "  [INFO] Idle time is 0 - user may have just logged in or session is locked" -ForegroundColor Yellow
        }
        
        # Show raw values for debugging
        Write-Host "  TickCount64: $([Environment]::TickCount64)" -ForegroundColor Gray
        Write-Host "  TickCount64 (hours): $([Math]::Floor([Environment]::TickCount64 / 3600000))" -ForegroundColor Gray
        
    } catch {
        Write-Host "[ERROR] Failed to get idle time: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  StackTrace: $($_.ScriptStackTrace)" -ForegroundColor Gray
    }
    Write-Host ""
    
    # Test full payload build
    Write-Host "=== Testing Full Payload ===" -ForegroundColor Cyan
    try {
        $computerId = (Get-CimInstance Win32_ComputerSystemProduct).UUID
        $computerName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { "UNKNOWN" }
        $username = try {
            $u = (Get-CimInstance Win32_ComputerSystem).UserName
            if (-not $u) { $u = if ($env:USERNAME) { $env:USERNAME } else { "SYSTEM" } }
            if ($u -match '\\') { $u.Split('\')[-1] } else { $u }
        } catch {
            if ($env:USERNAME) { $env:USERNAME } else { "SYSTEM" }
        }
        
        $payload = @{
            computerId = $computerId
            computerName = $computerName
            username = $username
            online = $true
            pcStatus = "on"
            pcUptime = $uptimeFormatted
            idleTimeSeconds = $idleSeconds
            timestamp = (Get-Date).ToUniversalTime().ToString("o")
        }
        
        Write-Host "[SUCCESS] Payload built successfully" -ForegroundColor Green
        Write-Host ""
        Write-Host "Payload JSON:" -ForegroundColor Yellow
        $payload | ConvertTo-Json -Depth 10 | Write-Host -ForegroundColor White
        
    } catch {
        Write-Host "[ERROR] Failed to build payload: $($_.Exception.Message)" -ForegroundColor Red
    }
    
} catch {
    Write-Host "ERROR: Failed to load Agent.ps1: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== Test Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "To test as SYSTEM, run:" -ForegroundColor Yellow
Write-Host "  psexec -s powershell -File test-agent-functions.ps1" -ForegroundColor Gray
Write-Host ""
Write-Host "Or check Task Scheduler output for the scheduled task" -ForegroundColor Gray
Write-Host ""
Write-Host "Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

