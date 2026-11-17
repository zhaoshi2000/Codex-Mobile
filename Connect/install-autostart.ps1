param(
    [string]$Config = "$env:USERPROFILE\.ifileplus-connect\bridge.config.json",
    [switch]$RegisterOnly,
    [string]$StartupRoot = ''
)
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'watchdog.ps1'
$arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $script + '" -Config "' + $Config + '"'
$startup = if ($StartupRoot) { [IO.Path]::GetFullPath($StartupRoot) } else { [Environment]::GetFolderPath('Startup') }
[void][IO.Directory]::CreateDirectory($startup)
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut((Join-Path $startup 'AstroGate Connect.lnk'))
$shortcut.TargetPath = (Get-Command powershell.exe).Source
$shortcut.Arguments = $arguments
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.WindowStyle = 7
$shortcut.IconLocation = (Join-Path $PSScriptRoot 'AstroGate.ico')
$shortcut.Description = 'AstroGate Connect · 登录后自动连接'
$shortcut.Save()
$oldShortcut = Join-Path $startup 'iFilePlus Connect.lnk'
if (Test-Path -LiteralPath $oldShortcut) { Remove-Item -LiteralPath $oldShortcut -Force }
if (!$RegisterOnly) { Start-Process powershell.exe -ArgumentList $arguments -WindowStyle Hidden }
if ($RegisterOnly) { Write-Output 'Startup shortcut registered.' }
else { Write-Output 'Installed for this Windows user. Starts Codex and the connection bridge after login; retries after a crash. Sleep, power-off and lack of network still prevent connections.' }
