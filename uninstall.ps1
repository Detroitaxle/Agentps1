#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Uninstall script for PC Monitoring Agent
.DESCRIPTION
    Removes the monitoring agent by stopping and removing the scheduled task,
    and optionally removing registry keys and data files.
.PARAMETER RemoveRegistry
    Remove registry keys (default: true)
.PARAMETER RemoveDataFiles
    Remove data directory and all files (default: false)
.PARAMETER ScriptPath
    Optional. Path to Agent.ps1 file to remove. Defaults to $env:ProgramFiles\MyAgent\Agent.ps1
.EXAMPLE
    .\uninstall.ps1
    Removes the scheduled task and registry keys, but keeps data files
.EXAMPLE
    .\uninstall.ps1 -RemoveDataFiles $true
    Removes everything including data files
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [bool]$RemoveRegistry = $true,
    
    [Parameter(Mandatory=$false)]
    [bool]$RemoveDataFiles = $false,
    
    [Parameter(Mandatory=$false)]
    [string]$ScriptPath = "$env:ProgramFiles\MyAgent\Agent.ps1"
)

$TaskName = "MyPCMonitor"
$RegistryPath = "HKLM:\SOFTWARE\MyMonitoringAgent"
$DataDirectory = "C:\ProgramData\MyAgent"

Write-Host "PC Monitoring Agent - Uninstaller" -ForegroundColor Cyan
Write-Host "==================================" -ForegroundColor Cyan
Write-Host ""

try {
    # Stop and remove scheduled task
    Write-Host "Checking for scheduled task..." -ForegroundColor Yellow
    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Write-Host "Stopping scheduled task: $TaskName" -ForegroundColor Yellow
        try {
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop
            Write-Host "Task stopped successfully" -ForegroundColor Green
        } catch {
            Write-Host "Warning: Could not stop task (may already be stopped): $($_.Exception.Message)" -ForegroundColor Yellow
        }
        
        Write-Host "Removing scheduled task: $TaskName" -ForegroundColor Yellow
        try {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
            Write-Host "Scheduled task removed successfully" -ForegroundColor Green
        } catch {
            Write-Host "Error: Failed to remove scheduled task: $($_.Exception.Message)" -ForegroundColor Red
            throw
        }
    } else {
        Write-Host "Scheduled task not found: $TaskName" -ForegroundColor Gray
    }
    
    # Remove registry keys
    if ($RemoveRegistry) {
        Write-Host ""
        Write-Host "Checking for registry keys..." -ForegroundColor Yellow
        if (Test-Path $RegistryPath) {
            Write-Host "Removing registry keys: $RegistryPath" -ForegroundColor Yellow
            Remove-Item -Path $RegistryPath -Recurse -Force -ErrorAction Stop
            Write-Host "Registry keys removed successfully" -ForegroundColor Green
        } else {
            Write-Host "Registry keys not found: $RegistryPath" -ForegroundColor Gray
        }
    } else {
        Write-Host ""
        Write-Host "Skipping registry removal (RemoveRegistry = false)" -ForegroundColor Gray
    }
    
    # Remove script file
    Write-Host ""
    Write-Host "Checking for script file..." -ForegroundColor Yellow
    if (Test-Path $ScriptPath) {
        Write-Host "Removing script file: $ScriptPath" -ForegroundColor Yellow
        try {
            # Check if file is in use (read-only or locked)
            $fileInfo = Get-Item -Path $ScriptPath -ErrorAction Stop
            if ($fileInfo.IsReadOnly) {
                $fileInfo.IsReadOnly = $false
            }
            Remove-Item -Path $ScriptPath -Force -ErrorAction Stop
            Write-Host "Script file removed successfully" -ForegroundColor Green
            
            # Remove script directory if empty
            $scriptDir = Split-Path -Path $ScriptPath -Parent
            try {
                $items = Get-ChildItem -Path $scriptDir -Force -ErrorAction Stop | Where-Object { $_.Name -ne '.' -and $_.Name -ne '..' }
                if ($items.Count -eq 0) {
                    Write-Host "Removing empty script directory: $scriptDir" -ForegroundColor Yellow
                    Remove-Item -Path $scriptDir -Force -ErrorAction Stop
                    Write-Host "Script directory removed successfully" -ForegroundColor Green
                } else {
                    Write-Host "Script directory not empty, keeping: $scriptDir" -ForegroundColor Gray
                }
            } catch {
                # Directory might not be empty or already removed, ignore
                Write-Host "Note: Could not remove script directory (may not be empty): $($_.Exception.Message)" -ForegroundColor Gray
            }
        } catch {
            Write-Host "Warning: Could not remove script file (may be in use): $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "You may need to manually delete: $ScriptPath" -ForegroundColor Yellow
        }
    } else {
        Write-Host "Script file not found: $ScriptPath" -ForegroundColor Gray
    }
    
    # Remove data files
    if ($RemoveDataFiles) {
        Write-Host ""
        Write-Host "Checking for data directory..." -ForegroundColor Yellow
        if (Test-Path $DataDirectory) {
            Write-Host "Removing data directory: $DataDirectory" -ForegroundColor Yellow
            Remove-Item -Path $DataDirectory -Recurse -Force -ErrorAction Stop
            Write-Host "Data directory removed successfully" -ForegroundColor Green
        } else {
            Write-Host "Data directory not found: $DataDirectory" -ForegroundColor Gray
        }
    } else {
        Write-Host ""
        Write-Host "Skipping data file removal (RemoveDataFiles = false)" -ForegroundColor Gray
        Write-Host "Data directory remains at: $DataDirectory" -ForegroundColor Gray
    }
    
    Write-Host ""
    Write-Host "Uninstallation completed successfully!" -ForegroundColor Green
    exit 0
    
} catch {
    Write-Host ""
    Write-Host "ERROR: Uninstallation failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    exit 1
}

