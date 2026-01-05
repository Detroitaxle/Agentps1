@echo off
REM Wrapper batch file for Install-Wizard.ps1
REM This ensures proper execution policy and shows errors

echo Starting Installation Wizard...
echo.

REM Check for administrator privileges
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo ERROR: This script requires Administrator privileges.
    echo Please right-click and select "Run as administrator"
    echo.
    pause
    exit /b 1
)

REM Run PowerShell with execution policy bypass
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Wizard.ps1"

if %errorLevel% neq 0 (
    echo.
    echo An error occurred. Error code: %errorLevel%
    pause
)

