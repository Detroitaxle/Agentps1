Set objShell = CreateObject("WScript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")

' Get the script directory
strScriptPath = objFSO.GetParentFolderName(WScript.ScriptFullName)
strAgentPath = strScriptPath & "\Agent.ps1"

' Build PowerShell command
strCommand = "powershell.exe -NoProfile -NonInteractive -NoLogo -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & strAgentPath & """"

' Run PowerShell completely hidden (0 = hidden window)
objShell.Run strCommand, 0, False

Set objShell = Nothing
Set objFSO = Nothing
