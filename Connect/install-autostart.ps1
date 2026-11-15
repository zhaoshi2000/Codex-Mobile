param([string]$Config = "$env:USERPROFILE\.ifileplus-connect\bridge.config.json")
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'watchdog.ps1'
$arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $script + '" -Config "' + $Config + '"'
$startup = [Environment]::GetFolderPath('Startup')
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut((Join-Path $startup 'iFilePlus Connect.lnk'))
$shortcut.TargetPath = (Get-Command powershell.exe).Source
$shortcut.Arguments = $arguments
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.WindowStyle = 7
$shortcut.Save()
Start-Process powershell.exe -ArgumentList $arguments -WindowStyle Hidden
Write-Output 'Installed for this Windows user. Starts Codex and the connection bridge after login; retries after a crash. Sleep, power-off and lack of network still prevent connections.'
