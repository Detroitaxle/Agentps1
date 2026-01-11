#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Updates the installed monitoring agent with the latest version.

.DESCRIPTION
    This script copies the latest Agent.ps1 from the script directory to the
    installation directory, updates the VBScript wrapper, and updates the
    scheduled task to use the wrapper if needed.
#>

Write-Host '=== Agent Update Script ===' -ForegroundColor Cyan
Write-Host ''

$sourceFile = Join-Path $PSScriptRoot 'Agent.ps1'
$targetFile = 'C:\Program Files\MyAgent\Agent.ps1'
$targetDir = Split-Path $targetFile -Parent
$TaskName = 'MyPCMonitor'
$ErrorOccurred = $false

Write-Host "Source file: $sourceFile" -ForegroundColor Gray
Write-Host "Target file: $targetFile" -ForegroundColor Gray
Write-Host ''

# check source file exists
if (-not (Test-Path $sourceFile)) {
    Write-Host "ERROR: Source file not found: $sourceFile" -ForegroundColor Red
    Write-Host ''
    Write-Host 'Press any key to exit...'
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    exit 1
}

# create target directory if needed
if (-not (Test-Path $targetDir)) {
    Write-Host "Creating directory: $targetDir" -ForegroundColor Yellow
    try {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        Write-Host 'Directory created successfully' -ForegroundColor Green
        Write-Host ''
    } catch {
        Write-Host "ERROR: Failed to create directory: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ''
        Write-Host 'Press any key to exit...'
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        exit 1
    }
}

# backup existing agent
if (Test-Path $targetFile) {
    $backupFile = "$targetFile.backup.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Write-Host "Backing up existing file to: $backupFile" -ForegroundColor Yellow
    try {
        Copy-Item -Path $targetFile -Destination $backupFile -Force
        Write-Host 'Backup created successfully' -ForegroundColor Green
        Write-Host ''
    } catch {
        Write-Host "WARNING: Failed to create backup: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host ''
    }
}

# copy new agent script
Write-Host 'Copying updated Agent.ps1...' -ForegroundColor Yellow
try {
    Copy-Item -Path $sourceFile -Destination $targetFile -Force
    Write-Host 'SUCCESS: Agent.ps1 updated successfully!' -ForegroundColor Green
    Write-Host ''
    
    # check files match
    $sourceHash = (Get-FileHash $sourceFile -Algorithm SHA256).Hash
    $targetHash = (Get-FileHash $targetFile -Algorithm SHA256).Hash
    
    if ($sourceHash -eq $targetHash) {
        Write-Host 'Verification: Files match (SHA256)' -ForegroundColor Green
    } else {
        Write-Host 'WARNING: File hashes do not match!' -ForegroundColor Red
        $ErrorOccurred = $true
    }
    Write-Host ''
} catch {
    Write-Host "ERROR: Failed to copy file: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ''
    Write-Host 'Press any key to exit...'
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    exit 1
}

# copy VBScript wrapper to hide window
$vbScriptSource = Join-Path $PSScriptRoot 'RunAgentHidden.vbs'
$vbScriptTarget = Join-Path $targetDir 'RunAgentHidden.vbs'

if (Test-Path $vbScriptSource) {
    Write-Host 'Copying VBScript wrapper...' -ForegroundColor Yellow
    try {
        Copy-Item -Path $vbScriptSource -Destination $vbScriptTarget -Force
        Write-Host 'VBScript wrapper updated successfully!' -ForegroundColor Green
        Write-Host ''
        
        # update task to use VBScript wrapper
        $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($existingTask) {
            Write-Host 'Updating scheduled task to use VBScript wrapper...' -ForegroundColor Yellow
            try {
                $task = Get-ScheduledTask -TaskName $TaskName
                $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbScriptTarget`""
                # keep existing task settings
                Set-ScheduledTask -TaskName $TaskName -Action $action -Trigger $task.Triggers -Principal $task.Principal -Settings $task.Settings | Out-Null
                Write-Host 'Scheduled task updated successfully!' -ForegroundColor Green
                Write-Host ''
            } catch {
                Write-Host "WARNING: Failed to update scheduled task: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host 'You may need to reinstall to use the VBScript wrapper.' -ForegroundColor Yellow
                Write-Host ''
                $ErrorOccurred = $true
            }
        } else {
            Write-Host "WARNING: Scheduled task '$TaskName' not found. Agent may not be installed." -ForegroundColor Yellow
            Write-Host ''
        }
    } catch {
        Write-Host "WARNING: Failed to copy VBScript wrapper: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host ''
        $ErrorOccurred = $true
    }
} else {
    Write-Host 'WARNING: RunAgentHidden.vbs not found - window flickering fix not applied' -ForegroundColor Yellow
    Write-Host ''
    $ErrorOccurred = $true
}

Write-Host 'The updated agent will be used on the next scheduled run (within 1 minute).' -ForegroundColor Cyan
Write-Host ''

if ($ErrorOccurred) {
    Write-Host 'Update completed with warnings. Please review the messages above.' -ForegroundColor Yellow
} else {
    Write-Host 'Update completed successfully!' -ForegroundColor Green
}
Write-Host ''
Write-Host 'Press any key to exit...'
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
