# Update Agent Script
# This script updates the installed Agent.ps1 with the latest version
# Must be run as Administrator

Write-Host "=== Agent Update Script ===" -ForegroundColor Cyan
Write-Host ""

# Check for administrator privileges
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "ERROR: This script requires Administrator privileges." -ForegroundColor Red
    Write-Host "Please right-click and select 'Run as administrator'" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

$sourceFile = Join-Path $PSScriptRoot "Agent.ps1"
$targetFile = "C:\Program Files\MyAgent\Agent.ps1"

Write-Host "Source file: $sourceFile" -ForegroundColor Gray
Write-Host "Target file: $targetFile" -ForegroundColor Gray
Write-Host ""

# Check if source file exists
if (-not (Test-Path $sourceFile)) {
    Write-Host "ERROR: Source file not found: $sourceFile" -ForegroundColor Red
    Write-Host ""
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

# Check if target directory exists
$targetDir = Split-Path $targetFile -Parent
if (-not (Test-Path $targetDir)) {
    Write-Host "Creating directory: $targetDir" -ForegroundColor Yellow
    try {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    } catch {
        Write-Host "ERROR: Failed to create directory: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "Press any key to exit..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        exit 1
    }
}

# Backup existing file if it exists
if (Test-Path $targetFile) {
    $backupFile = "$targetFile.backup.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Write-Host "Backing up existing file to: $backupFile" -ForegroundColor Yellow
    try {
        Copy-Item -Path $targetFile -Destination $backupFile -Force
        Write-Host "Backup created successfully" -ForegroundColor Green
    } catch {
        Write-Host "WARNING: Failed to create backup: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    Write-Host ""
}

# Copy the updated file
Write-Host "Copying updated Agent.ps1..." -ForegroundColor Yellow
try {
    Copy-Item -Path $sourceFile -Destination $targetFile -Force
    Write-Host "SUCCESS: Agent.ps1 updated successfully!" -ForegroundColor Green
    Write-Host ""
    
    # Verify the file
    $sourceHash = (Get-FileHash $sourceFile -Algorithm SHA256).Hash
    $targetHash = (Get-FileHash $targetFile -Algorithm SHA256).Hash
    
    if ($sourceHash -eq $targetHash) {
        Write-Host "Verification: Files match (SHA256)" -ForegroundColor Green
    } else {
        Write-Host "WARNING: File hashes do not match!" -ForegroundColor Red
    }
    
    Write-Host ""
    Write-Host "The updated agent will be used on the next scheduled run (within 1 minute)." -ForegroundColor Cyan
    Write-Host ""
    
} catch {
    Write-Host "ERROR: Failed to copy file: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

Write-Host "Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

