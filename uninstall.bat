@echo off
:: Uninstall wrapper for PC Monitoring Agent
:: Ensures script runs with administrator privileges

:: Check for Administrator privileges
NET SESSION >NUL 2>&1
IF %ERRORLEVEL% NEQ 0 (
    ECHO This script requires Administrator privileges.
    ECHO Please right-click and select "Run as administrator".
    PAUSE
    EXIT /B 1
)

:: Set execution policy for the current process only
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
PAUSE


