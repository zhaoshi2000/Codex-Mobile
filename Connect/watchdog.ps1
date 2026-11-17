param([string]$Config = "$env:USERPROFILE\.ifileplus-connect\bridge.config.json")
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'find-codex.ps1')
$mutex = New-Object Threading.Mutex($false, 'Local\iFilePlusConnectWatchdog')
$locked = $false
try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
if (!$locked) { $mutex.Dispose(); exit }
try {
    while ($true) {
        try {
            $settings = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json
            $cli = Find-CodexExecutable -Preferred $settings.codexExecutable
            if (!(Test-Path -LiteralPath '\\.\pipe\codex-ipc')) {
                if (Start-CodexDesktop -CodexCli $cli -Hidden) { Start-Sleep -Seconds 10 }
            }
            & (Join-Path $PSScriptRoot 'start.ps1') -Config $Config -NoShowQR -EnsureRunning | Out-Null
        } catch {
            # No credentials or chat contents are written to this log.
            $log = Join-Path $env:USERPROFILE '.ifileplus-connect\watchdog-status.txt'
            [IO.File]::WriteAllText($log, (Get-Date -Format o) + ' Waiting for Codex or network; retrying in 30 seconds.')
        }
        Start-Sleep -Seconds 30
    }
} finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
