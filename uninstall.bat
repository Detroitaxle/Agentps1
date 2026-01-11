@echo off
:: Uninstall script for PC Monitoring Agent
:: Wrapper batch file for Uninstall-Agent.ps1

echo Starting Uninstaller...
echo.

REM Check for Administrator privileges
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo ERROR: This script requires Administrator privileges.
    echo Please right-click and select "Run as administrator"
    echo.
    pause
    exit /b 1
)

REM Run PowerShell script
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall-Agent.ps1"

if %errorLevel% neq 0 (
    echo.
    echo An error occurred. Error code: %errorLevel%
    pause
)
