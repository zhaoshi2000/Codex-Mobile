param([string]$Config = "$env:USERPROFILE\.ifileplus-connect\bridge.config.json")
$ErrorActionPreference = 'Stop'
$mutex = New-Object Threading.Mutex($false, 'Local\iFilePlusConnectWatchdog')
if (!$mutex.WaitOne(0)) { $mutex.Dispose(); exit }
try {
    while ($true) {
        try {
            $settings = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json
            $package = Get-AppxPackage -Name OpenAI.Codex | Select-Object -First 1
            if ($package) {
                $cli = Join-Path $package.InstallLocation 'app\resources\codex.exe'
                if ((Test-Path -LiteralPath $cli) -and $settings.codexExecutable -ne $cli) {
                    $settings.codexExecutable = $cli
                    [IO.File]::WriteAllText($Config, ($settings | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
                }
                $desktop = Join-Path $package.InstallLocation 'app\Codex.exe'
                $running = Get-CimInstance Win32_Process -Filter "Name='Codex.exe'" | Where-Object { $_.ExecutablePath -eq $desktop }
                if (!$running -and (Test-Path -LiteralPath $desktop)) {
                    Start-Process -FilePath $desktop -WindowStyle Hidden
                    Start-Sleep -Seconds 10
                }
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
