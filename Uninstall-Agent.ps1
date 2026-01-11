#Requires -Version 5.1
#Requires -RunAsAdministrator
# Uninstall script for PC Monitoring Agent

$TaskName = 'MyPCMonitor'
$RegistryPath = 'HKLM:\SOFTWARE\MyMonitoringAgent'
$DataDirectory = 'C:\ProgramData\MyAgent'
$ScriptPath = "$env:ProgramFiles\MyAgent\Agent.ps1"
$RemoveRegistry = $true
$RemoveDataFiles = $false

Write-Host 'PC Monitoring Agent - Uninstaller' -ForegroundColor Cyan
Write-Host '==================================' -ForegroundColor Cyan
Write-Host ''

try {
    # stop and remove task
    Write-Host 'Checking for scheduled task...' -ForegroundColor Yellow
    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Write-Host "Stopping scheduled task: $TaskName" -ForegroundColor Yellow
        try {
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop
            Write-Host 'Task stopped successfully' -ForegroundColor Green
        } catch {
            Write-Host "Warning: Could not stop task (may already be stopped): $($_.Exception.Message)" -ForegroundColor Yellow
        }
        
        Write-Host "Removing scheduled task: $TaskName" -ForegroundColor Yellow
        try {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
            Write-Host 'Scheduled task removed successfully' -ForegroundColor Green
        } catch {
            Write-Host "Error: Failed to remove scheduled task: $($_.Exception.Message)" -ForegroundColor Red
            throw
        }
    } else {
        Write-Host "Scheduled task not found: $TaskName" -ForegroundColor Gray
    }
    
    # remove registry
    if ($RemoveRegistry) {
        Write-Host ''
        Write-Host 'Checking for registry keys...' -ForegroundColor Yellow
        if (Test-Path $RegistryPath) {
            Write-Host "Removing registry keys: $RegistryPath" -ForegroundColor Yellow
            Remove-Item -Path $RegistryPath -Recurse -Force -ErrorAction Stop
            Write-Host 'Registry keys removed successfully' -ForegroundColor Green
        } else {
            Write-Host "Registry keys not found: $RegistryPath" -ForegroundColor Gray
        }
    } else {
        Write-Host ''
        Write-Host 'Skipping registry removal (RemoveRegistry = false)' -ForegroundColor Gray
    }
    
    # remove script files
    Write-Host ''
    Write-Host 'Checking for script files...' -ForegroundColor Yellow
    $scriptDir = Split-Path -Path $ScriptPath -Parent
    $vbScriptPath = Join-Path $scriptDir 'RunAgentHidden.vbs'
    
    # remove Agent.ps1
    if (Test-Path $ScriptPath) {
        Write-Host "Removing script file: $ScriptPath" -ForegroundColor Yellow
        try {
            $fileInfo = Get-Item -Path $ScriptPath -ErrorAction Stop
            if ($fileInfo.IsReadOnly) {
                $fileInfo.IsReadOnly = $false
            }
            Remove-Item -Path $ScriptPath -Force -ErrorAction Stop
            Write-Host 'Script file removed successfully' -ForegroundColor Green
        } catch {
            Write-Host "Warning: Could not remove script file (may be in use): $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "You may need to manually delete: $ScriptPath" -ForegroundColor Yellow
        }
    } else {
        Write-Host "Script file not found: $ScriptPath" -ForegroundColor Gray
    }
    
    # remove VBScript wrapper
    if (Test-Path $vbScriptPath) {
        Write-Host "Removing VBScript wrapper: $vbScriptPath" -ForegroundColor Yellow
        try {
            Remove-Item -Path $vbScriptPath -Force -ErrorAction Stop
            Write-Host 'VBScript wrapper removed successfully' -ForegroundColor Green
        } catch {
            Write-Host "Warning: Could not remove VBScript wrapper: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    
    # remove directory if empty
    if (Test-Path $scriptDir) {
        try {
            $items = Get-ChildItem -Path $scriptDir -Force -ErrorAction Stop | Where-Object { $_.Name -ne '.' -and $_.Name -ne '..' }
            if ($items.Count -eq 0) {
                Write-Host "Removing empty script directory: $scriptDir" -ForegroundColor Yellow
                Remove-Item -Path $scriptDir -Force -ErrorAction Stop
                Write-Host 'Script directory removed successfully' -ForegroundColor Green
            } else {
                Write-Host "Script directory not empty, keeping: $scriptDir" -ForegroundColor Gray
            }
        } catch {
            Write-Host "Note: Could not remove script directory (may not be empty): $($_.Exception.Message)" -ForegroundColor Gray
        }
    }
    
    # remove data files
    if ($RemoveDataFiles) {
        Write-Host ''
        Write-Host 'Checking for data directory...' -ForegroundColor Yellow
        if (Test-Path $DataDirectory) {
            Write-Host "Removing data directory: $DataDirectory" -ForegroundColor Yellow
            Remove-Item -Path $DataDirectory -Recurse -Force -ErrorAction Stop
            Write-Host 'Data directory removed successfully' -ForegroundColor Green
        } else {
            Write-Host "Data directory not found: $DataDirectory" -ForegroundColor Gray
        }
    } else {
        Write-Host ''
        Write-Host 'Skipping data file removal (RemoveDataFiles = false)' -ForegroundColor Gray
        Write-Host "Data directory remains at: $DataDirectory" -ForegroundColor Gray
    }
    
    Write-Host ''
    Write-Host 'Uninstallation completed successfully!' -ForegroundColor Green
    Write-Host ''
    Write-Host 'Press any key to exit...' -ForegroundColor Cyan
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    exit 0
    
} catch {
    Write-Host ''
    Write-Host "ERROR: Uninstallation failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    Write-Host ''
    Write-Host 'Press any key to exit...' -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    exit 1
}
