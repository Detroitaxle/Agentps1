@echo off
:: Update Agent Batch File
:: This will launch the PowerShell update script with administrator privileges

:: Check for Administrator privileges
NET SESSION >NUL 2>&1
IF %ERRORLEVEL% NEQ 0 (
    ECHO This script requires Administrator privileges.
    ECHO Please right-click and select "Run as administrator".
    PAUSE
    EXIT /B 1
)

:: Run the PowerShell update script
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-agent.ps1"
PAUSE

