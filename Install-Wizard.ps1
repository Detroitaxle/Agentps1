#Requires -Version 5.1
#Requires -RunAsAdministrator
# GUI installer with Windows Forms

$ErrorActionPreference = "Stop"

# load Windows Forms
try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
} catch {
    # Forms not available, will use console instead
}

try {
    # check admin privileges
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    
    if (-not $isAdmin) {
        $errorMsg = "This installation wizard requires Administrator privileges.`n`n" +
                    "RECOMMENDED: Use Install-Wizard.bat and right-click 'Run as administrator'`n`n" +
                    "Or run PowerShell as Administrator and execute: .\Install-Wizard.ps1"
        try {
            [System.Windows.Forms.MessageBox]::Show(
                $errorMsg,
                "Administrator Required",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        } catch {
            Write-Host $errorMsg -ForegroundColor Red
            Write-Host "`nPress any key to exit..."
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        }
        exit 1
    }
    
    # load Windows Forms
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
} catch {
    $errorMsg = "Failed to initialize: $($_.Exception.Message)`n`nPlease ensure you are running as Administrator and that Windows Forms is available.`n`nTry using Install-Wizard.bat instead."
    try {
        [System.Windows.Forms.MessageBox]::Show($errorMsg, "Initialization Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    } catch {
        Write-Host $errorMsg -ForegroundColor Red
        Write-Host "`nPress any key to exit..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
    exit 1
}

#region GUI Form Creation

$form = New-Object System.Windows.Forms.Form
$form.Text = "PC Monitoring Agent - Installation Wizard"
$form.Size = New-Object System.Drawing.Size(600, 450)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.TopMost = $true

#endregion

#region Global Variables

$script:connectionTested = $false
$script:testResult = $null

#endregion

#region Helper Functions

function Test-UrlFormat {
    param([string]$Url)
    
    try {
        $uri = [System.Uri]::new($Url)
        return ($uri.Scheme -eq "http" -or $uri.Scheme -eq "https") -and $uri.Host -ne ""
    } catch {
        return $false
    }
}

function Test-ApiConnection {
    param(
        [string]$ApiUrl,
        [string]$ApiKey
    )
    
    try {
        $headers = @{
            "Content-Type" = "application/json"
            "X-API-KEY" = $ApiKey
        }
        
        # send a test payload
        $testPayload = @{
            computerId = "test-connection"
            computerName = "TEST"
            username = "TEST"
            online = $true
            pcStatus = "on"
            pcUptime = "00:00:00"
            idleTimeSeconds = 0
            timestamp = (Get-Date).ToUniversalTime().ToString("o")
        } | ConvertTo-Json -Compress
        
        # try sending to API
        try {
            $response = Invoke-RestMethod -Uri $ApiUrl -Method Post -Headers $headers -Body $testPayload -ContentType "application/json" -TimeoutSec 10 -ErrorAction Stop
            $responseJson = if ($response) { $response | ConvertTo-Json -Compress } else { "OK" }
            return @{ Success = $true; Message = "Connection successful - API responded with: $responseJson" }
        } catch {
            # check if we can reach the server
            $httpException = $_.Exception
            if ($httpException.Response) {
                try {
                    $statusCode = $httpException.Response.StatusCode.value__
                    # these errors mean server is reachable, just wrong auth/data
                    if ($statusCode -in @(400, 401, 403)) {
                        return @{ Success = $true; Message = "Server responded (Status $statusCode) - endpoint is reachable" }
                    }
                    # other error codes
                    return @{ Success = $false; Message = "Server responded with HTTP $statusCode - check API endpoint and key" }
                } catch {
                    # server responded but couldn't get status code
                    return @{ Success = $true; Message = "Server responded (endpoint is reachable)" }
                }
            }
            throw
        }
    } catch {
        return @{ Success = $false; Message = "Connection failed: $($_.Exception.Message)" }
    }
}

function Install-Agent {
    param(
        [string]$ApiUrl,
        [string]$ApiKey,
        [string]$ScriptPath
    )
    
    $TaskName = "MyPCMonitor"
    $RegistryPath = "HKLM:\SOFTWARE\MyMonitoringAgent"
    $DataDirectory = "C:\ProgramData\MyAgent"
    
    try {
        # set up registry
        if (-not (Test-Path $RegistryPath)) {
            $null = New-Item -Path $RegistryPath -Force
        }
        Set-ItemProperty -Path $RegistryPath -Name "ApiUrl" -Value $ApiUrl -Type String
        Set-ItemProperty -Path $RegistryPath -Name "ApiKey" -Value $ApiKey -Type String
        
        # create data directory
        if (-not (Test-Path $DataDirectory)) {
            $null = New-Item -ItemType Directory -Path $DataDirectory -Force
        }
        
        # create install directory
        $scriptDir = Split-Path -Path $ScriptPath -Parent
        if (-not (Test-Path $scriptDir)) {
            $null = New-Item -ItemType Directory -Path $scriptDir -Force
        }
        
        # copy agent script
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
                Copy-Item -Path $currentScript -Destination $ScriptPath -Force
            }
        } elseif (-not (Test-Path $ScriptPath)) {
            throw "Agent.ps1 not found in script directory and target path does not exist"
        }
        
        # copy VBScript wrapper to hide window
        $vbScriptSource = if ($PSScriptRoot) {
            Join-Path $PSScriptRoot "RunAgentHidden.vbs"
        } else {
            Join-Path (Get-Location) "RunAgentHidden.vbs"
        }
        $vbScriptTarget = Join-Path $scriptDir "RunAgentHidden.vbs"
        
        if (Test-Path $vbScriptSource) {
            Copy-Item -Path $vbScriptSource -Destination $vbScriptTarget -Force
        }
        
        # remove existing task if present
        $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($existingTask) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        }
        
        # create scheduled task using VBScript wrapper
        $vbScriptPath = Join-Path $scriptDir "RunAgentHidden.vbs"
        if (Test-Path $vbScriptPath) {
            $action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$vbScriptPath`""
        } else {
            # use PowerShell directly if VBScript missing
            $action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-NoProfile -NonInteractive -NoLogo -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""
        }
        
        # run every minute
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 365)
        
        # run as current user
        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        # strip domain
        if ($currentUser -match '\\') {
            $currentUser = $currentUser.Split('\')[-1]
        }
        $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Highest
        
        # keep task hidden
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable:$false -Hidden
        
        # register the task
        $null = Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "PC Monitoring Agent - Sends heartbeat data to monitoring API"
        
        # start it
        Start-ScheduledTask -TaskName $TaskName
        
        return @{ Success = $true; Message = "Installation completed successfully!" }
    } catch {
        return @{ Success = $false; Message = "Installation failed: $($_.Exception.Message)" }
    }
}

#endregion

#region GUI Controls

# API URL Label and TextBox
$lblApiUrl = New-Object System.Windows.Forms.Label
$lblApiUrl.Location = New-Object System.Drawing.Point(20, 20)
$lblApiUrl.Size = New-Object System.Drawing.Size(200, 20)
$lblApiUrl.Text = "API Endpoint URL:"
$form.Controls.Add($lblApiUrl)

$txtApiUrl = New-Object System.Windows.Forms.TextBox
$txtApiUrl.Location = New-Object System.Drawing.Point(20, 45)
$txtApiUrl.Size = New-Object System.Drawing.Size(540, 23)
$txtApiUrl.TabIndex = 0
$form.Controls.Add($txtApiUrl)

# API Key Label and TextBox
$lblApiKey = New-Object System.Windows.Forms.Label
$lblApiKey.Location = New-Object System.Drawing.Point(20, 85)
$lblApiKey.Size = New-Object System.Drawing.Size(200, 20)
$lblApiKey.Text = "API Key:"
$form.Controls.Add($lblApiKey)

$txtApiKey = New-Object System.Windows.Forms.TextBox
$txtApiKey.Location = New-Object System.Drawing.Point(20, 110)
$txtApiKey.Size = New-Object System.Drawing.Size(540, 23)
$txtApiKey.PasswordChar = '*'
$txtApiKey.TabIndex = 1
$form.Controls.Add($txtApiKey)

# Script Path Label and TextBox
$lblScriptPath = New-Object System.Windows.Forms.Label
$lblScriptPath.Location = New-Object System.Drawing.Point(20, 150)
$lblScriptPath.Size = New-Object System.Drawing.Size(200, 20)
$lblScriptPath.Text = "Agent.ps1 Location:"
$form.Controls.Add($lblScriptPath)

$txtScriptPath = New-Object System.Windows.Forms.TextBox
$txtScriptPath.Location = New-Object System.Drawing.Point(20, 175)
$txtScriptPath.Size = New-Object System.Drawing.Size(450, 23)
$txtScriptPath.Text = "$env:ProgramFiles\MyAgent\Agent.ps1"
$txtScriptPath.TabIndex = 2
$form.Controls.Add($txtScriptPath)

# Browse Button
$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Location = New-Object System.Drawing.Point(480, 174)
$btnBrowse.Size = New-Object System.Drawing.Size(80, 25)
$btnBrowse.Text = "Browse..."
$btnBrowse.TabIndex = 3
$btnBrowse.Add_Click({
    $openFileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $openFileDialog.Filter = "PowerShell Scripts (*.ps1)|*.ps1|All Files (*.*)|*.*"
    $openFileDialog.Title = "Select Agent.ps1"
    if ($openFileDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtScriptPath.Text = $openFileDialog.FileName
    }
})
$form.Controls.Add($btnBrowse)

# Status Label
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(20, 210)
$lblStatus.Size = New-Object System.Drawing.Size(540, 40)
$lblStatus.Text = ""
$lblStatus.ForeColor = [System.Drawing.Color]::Blue
$form.Controls.Add($lblStatus)

# Test Connection Button
$btnTestConnection = New-Object System.Windows.Forms.Button
$btnTestConnection.Location = New-Object System.Drawing.Point(20, 260)
$btnTestConnection.Size = New-Object System.Drawing.Size(130, 30)
$btnTestConnection.Text = "Test Connection"
$btnTestConnection.TabIndex = 4
$btnTestConnection.Add_Click({
    $lblStatus.Text = "Testing connection..."
    $lblStatus.ForeColor = [System.Drawing.Color]::Blue
    $form.Refresh()
    
    # check inputs
    if ([string]::IsNullOrWhiteSpace($txtApiUrl.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Please enter an API URL.", "Validation Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        $lblStatus.Text = ""
        return
    }
    
    if (-not (Test-UrlFormat -Url $txtApiUrl.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Invalid URL format. Please enter a valid HTTP or HTTPS URL.", "Validation Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        $lblStatus.Text = ""
        return
    }
    
    if ([string]::IsNullOrWhiteSpace($txtApiKey.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Please enter an API Key.", "Validation Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        $lblStatus.Text = ""
        return
    }
    
    # test it
    $result = Test-ApiConnection -ApiUrl $txtApiUrl.Text -ApiKey $txtApiKey.Text
    $script:connectionTested = $true
    $script:testResult = $result
    
    if ($result.Success) {
        $lblStatus.Text = "[OK] Connection test successful!"
        $lblStatus.ForeColor = [System.Drawing.Color]::Green
        [System.Windows.Forms.MessageBox]::Show($result.Message, "Connection Test Successful", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    } else {
        $lblStatus.Text = "[FAILED] Connection test failed"
        $lblStatus.ForeColor = [System.Drawing.Color]::Red
        [System.Windows.Forms.MessageBox]::Show($result.Message, "Connection Test Failed", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
})
$form.Controls.Add($btnTestConnection)

# Install Button
$btnInstall = New-Object System.Windows.Forms.Button
$btnInstall.Location = New-Object System.Drawing.Point(430, 260)
$btnInstall.Size = New-Object System.Drawing.Size(130, 30)
$btnInstall.Text = "Install"
$btnInstall.TabIndex = 5
$btnInstall.Add_Click({
    # check inputs
    if ([string]::IsNullOrWhiteSpace($txtApiUrl.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Please enter an API URL.", "Validation Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    
    if (-not (Test-UrlFormat -Url $txtApiUrl.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Invalid URL format. Please enter a valid HTTP or HTTPS URL.", "Validation Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    
    if ([string]::IsNullOrWhiteSpace($txtApiKey.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Please enter an API Key.", "Validation Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    
    if ([string]::IsNullOrWhiteSpace($txtScriptPath.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Please specify the Agent.ps1 script path.", "Validation Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    
    # make sure Agent.ps1 exists
    $currentScript = if ($PSScriptRoot) {
        Join-Path $PSScriptRoot "Agent.ps1"
    } else {
        Join-Path (Get-Location) "Agent.ps1"
    }
    if (-not (Test-Path $currentScript) -and -not (Test-Path $txtScriptPath.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Agent.ps1 not found. Please ensure Agent.ps1 is in the same directory as this installer, or specify an existing script path.", "File Not Found", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    
    # warn if not tested
    if (-not $script:connectionTested) {
        $result = [System.Windows.Forms.MessageBox]::Show("You have not tested the connection. Do you want to continue with installation anyway?", "Confirm Installation", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($result -ne [System.Windows.Forms.DialogResult]::Yes) {
            return
        }
    } elseif ($script:testResult -and -not $script:testResult.Success) {
        $result = [System.Windows.Forms.MessageBox]::Show("Connection test failed. Do you want to continue with installation anyway?", "Confirm Installation", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($result -ne [System.Windows.Forms.DialogResult]::Yes) {
            return
        }
    }
    
    # disable buttons while installing
    $btnInstall.Enabled = $false
    $btnTestConnection.Enabled = $false
    $btnBrowse.Enabled = $false
    
    $lblStatus.Text = "Installing..."
    $lblStatus.ForeColor = [System.Drawing.Color]::Blue
    $form.Refresh()
    
    # do the install
    $installResult = Install-Agent -ApiUrl $txtApiUrl.Text -ApiKey $txtApiKey.Text -ScriptPath $txtScriptPath.Text
    
    if ($installResult.Success) {
        $lblStatus.Text = "Installation completed successfully!"
        $lblStatus.ForeColor = [System.Drawing.Color]::Green
        [System.Windows.Forms.MessageBox]::Show($installResult.Message + "`n`nThe monitoring agent will start running immediately and continue after system reboots.", "Installation Successful", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        $form.Close()
    } else {
        $lblStatus.Text = "Installation failed"
        $lblStatus.ForeColor = [System.Drawing.Color]::Red
        [System.Windows.Forms.MessageBox]::Show($installResult.Message, "Installation Failed", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        $btnInstall.Enabled = $true
        $btnTestConnection.Enabled = $true
        $btnBrowse.Enabled = $true
    }
})
$form.Controls.Add($btnInstall)

# Cancel Button
$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Location = New-Object System.Drawing.Point(290, 260)
$btnCancel.Size = New-Object System.Drawing.Size(130, 30)
$btnCancel.Text = "Cancel"
$btnCancel.TabIndex = 6
$btnCancel.Add_Click({
    $form.Close()
})
$form.Controls.Add($btnCancel)

#endregion

#region Main Execution

try {
    # show the form
    [System.Windows.Forms.Application]::Run($form)
} catch {
    $errorMsg = "An error occurred while running the wizard: $($_.Exception.Message)"
    try {
        [System.Windows.Forms.MessageBox]::Show($errorMsg, "Runtime Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    } catch {
        Write-Host $errorMsg -ForegroundColor Red
        Write-Host "Press any key to exit..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
    exit 1
}

#endregion

