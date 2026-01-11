@echo off
:: Update Agent Script
:: Updates the installed Agent.ps1 with the latest version

:: Run the PowerShell update script
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-Agent.ps1"

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo Update failed with error code: %ERRORLEVEL%
    pause
)

