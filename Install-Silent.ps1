#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Silent installation script for PC Monitoring Agent
.DESCRIPTION
    Installs the monitoring agent without GUI. Suitable for command-line installation.
    Requires Administrator privileges.
.PARAMETER ApiUrl
    The API endpoint URL where heartbeats will be sent
.PARAMETER ApiKey
    The API key for authentication
.PARAMETER ScriptPath
    Optional. Path where Agent.ps1 will be installed. Defaults to $env:ProgramFiles\MyAgent\Agent.ps1
.EXAMPLE
    .\Install-Silent.ps1 -ApiUrl "https://api.example.com/heartbeat" -ApiKey "your-api-key-here"
.EXAMPLE
    .\Install-Silent.ps1 -ApiUrl "https://api.example.com/heartbeat" -ApiKey "your-api-key" -ScriptPath "C:\Custom\Path\Agent.ps1"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ApiUrl,
    
    [Parameter(Mandatory=$true)]
    [string]$ApiKey,
    
    [Parameter(Mandatory=$false)]
    [string]$ScriptPath = "$env:ProgramFiles\MyAgent\Agent.ps1"
)

$TaskName = "MyPCMonitor"
$RegistryPath = "HKLM:\SOFTWARE\MyMonitoringAgent"
$DataDirectory = "C:\ProgramData\MyAgent"
$InstallLogFile = Join-Path $DataDirectory "install.log"

function Write-InstallLog {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    try {
        # Ensure log directory exists
        $logDir = Split-Path -Path $InstallLogFile -Parent
        if (-not (Test-Path $logDir)) {
            $null = New-Item -ItemType Directory -Path $logDir -Force -ErrorAction Stop
        }
        Add-Content -Path $InstallLogFile -Value $logMessage -ErrorAction Stop
    } catch {
        # If we can't write to log, write to console
        Write-Host $logMessage
    }
    Write-Host $logMessage
}

function Test-UrlFormat {
    param([string]$Url)
    try {
        $uri = [System.Uri]::new($Url)
        return ($uri.Scheme -eq "http" -or $uri.Scheme -eq "https") -and $uri.Host -ne ""
    } catch {
        return $false
    }
}

# Validate inputs
if ([string]::IsNullOrWhiteSpace($ApiUrl)) {
    Write-InstallLog "ERROR: ApiUrl parameter is required" "ERROR"
    exit 1
}

if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    Write-InstallLog "ERROR: ApiKey parameter is required" "ERROR"
    exit 1
}

if (-not (Test-UrlFormat -Url $ApiUrl)) {
    Write-InstallLog "ERROR: Invalid URL format. Must be a valid HTTP or HTTPS URL" "ERROR"
    exit 1
}

Write-InstallLog "Starting silent installation..."
Write-InstallLog "API URL: $ApiUrl"
Write-InstallLog "Script Path: $ScriptPath"

try {
    # Create registry keys
    Write-InstallLog "Creating registry keys..."
    if (-not (Test-Path $RegistryPath)) {
        $null = New-Item -Path $RegistryPath -Force -ErrorAction Stop
        Write-InstallLog "Created registry path: $RegistryPath"
    }
    Set-ItemProperty -Path $RegistryPath -Name "ApiUrl" -Value $ApiUrl -Type String -ErrorAction Stop
    Set-ItemProperty -Path $RegistryPath -Name "ApiKey" -Value $ApiKey -Type String -ErrorAction Stop
    Write-InstallLog "Registry keys created successfully"
    
    # Create data directory
    Write-InstallLog "Creating data directory..."
    if (-not (Test-Path $DataDirectory)) {
        $null = New-Item -ItemType Directory -Path $DataDirectory -Force -ErrorAction Stop
        Write-InstallLog "Created data directory: $DataDirectory"
    } else {
        Write-InstallLog "Data directory already exists: $DataDirectory"
    }
    
    # Ensure script directory exists and copy script if needed
    Write-InstallLog "Preparing script location..."
    $scriptDir = Split-Path -Path $ScriptPath -Parent
    if (-not (Test-Path $scriptDir)) {
        $null = New-Item -ItemType Directory -Path $scriptDir -Force -ErrorAction Stop
        Write-InstallLog "Created script directory: $scriptDir"
    }
    
    # Copy Agent.ps1 to target location if it's different from current location
    $currentScript = if ($PSScriptRoot) {
        Join-Path $PSScriptRoot "Agent.ps1"
    } else {
        Join-Path (Get-Location) "Agent.ps1"
    }
    
    if (Test-Path $currentScript) {
        $currentScriptResolved = (Resolve-Path $currentScript).Path
        $targetScriptResolved = if (Test-Path $ScriptPath) {
            (Resolve-Path $ScriptPath).Path
        } else {
            $ScriptPath
        }
        
        if ($currentScriptResolved -ne $targetScriptResolved) {
            Copy-Item -Path $currentScript -Destination $ScriptPath -Force -ErrorAction Stop
            Write-InstallLog "Copied Agent.ps1 to: $ScriptPath"
        } else {
            Write-InstallLog "Agent.ps1 already at target location"
        }
    } elseif (-not (Test-Path $ScriptPath)) {
        Write-InstallLog "ERROR: Agent.ps1 not found in script directory and target path does not exist" "ERROR"
        exit 1
    } else {
        Write-InstallLog "Using existing Agent.ps1 at: $ScriptPath"
    }
    
    # Remove existing task if it exists
    Write-InstallLog "Checking for existing scheduled task..."
    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-InstallLog "Removed existing scheduled task: $TaskName"
    }
    
    # Create scheduled task action
    Write-InstallLog "Creating scheduled task..."
    $action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""
    
    # Create scheduled task trigger (every 1 minute)
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 365)
    
    # Create scheduled task principal (run as logged-in user to allow GetLastInputInfo to work)
    # Get the current logged-in user (works even when running as admin)
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    # Extract username if domain format (DOMAIN\username -> username)
    if ($currentUser -match '\\') {
        $currentUser = $currentUser.Split('\\')[-1]
    }
    $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Highest
    
    # Create scheduled task settings with Hidden flag to prevent window flashing
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable:$false -Hidden
    
    # Register the scheduled task
    $null = Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "PC Monitoring Agent - Sends heartbeat data to monitoring API" -ErrorAction Stop
    Write-InstallLog "Scheduled task registered: $TaskName"
    
    # Start the task immediately
    Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    Write-InstallLog "Scheduled task started: $TaskName"
    
    Write-InstallLog "Installation completed successfully!" "SUCCESS"
    Write-Host ""
    Write-Host "Installation completed successfully!" -ForegroundColor Green
    Write-Host "Task Name: $TaskName" -ForegroundColor Cyan
    Write-Host "Runs: Every 1 minute" -ForegroundColor Cyan
    Write-Host "Account: $currentUser (Interactive)" -ForegroundColor Cyan
    Write-Host "Installation log: $InstallLogFile" -ForegroundColor Cyan
    exit 0
    
} catch {
    $errorMessage = "Installation failed: $($_.Exception.Message)"
    Write-InstallLog $errorMessage "ERROR"
    Write-InstallLog $_.ScriptStackTrace "ERROR"
    Write-Host ""
    Write-Host $errorMessage -ForegroundColor Red
    Write-Host "Installation log: $InstallLogFile" -ForegroundColor Yellow
    exit 1
}

