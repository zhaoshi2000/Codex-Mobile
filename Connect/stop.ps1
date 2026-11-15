param([string]$Config = "$env:USERPROFILE\.ifileplus-connect\bridge.config.json")
$ErrorActionPreference = 'Stop'
$configPath = (Resolve-Path -LiteralPath $Config).Path
$settings = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
$statePath = if ($settings.stateDir) { $settings.stateDir } else { Join-Path $env:USERPROFILE '.ifileplus-connect' }
$pidFile = Join-Path $statePath 'bridge.pid'
$bridgeFile = Join-Path $PSScriptRoot 'src\bridge.mjs'
if (!(Test-Path -LiteralPath $pidFile)) { Write-Output 'Bridge is not running.'; exit }
$savedPid = [int](Get-Content -LiteralPath $pidFile -Raw)
$old = Get-CimInstance Win32_Process -Filter "ProcessId=$savedPid"
if ($old) {
    if ($old.Name -ne 'node.exe' -or !$old.CommandLine.Contains($bridgeFile) -or !$old.CommandLine.Contains($configPath)) { throw 'PID belongs to another process; refusing to stop it.' }
    Stop-Process -Id $savedPid -ErrorAction Stop
}
Remove-Item -LiteralPath $pidFile
Write-Output 'Bridge stopped.'
