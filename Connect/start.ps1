param([string]$Config = "$env:USERPROFILE\.ifileplus-connect\bridge.config.json", [switch]$NoShowQR, [switch]$Restart, [switch]$EnsureRunning)
$ErrorActionPreference = 'Stop'
$configPath = (Resolve-Path -LiteralPath $Config).Path
$settings = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
$statePath = if ($settings.stateDir) { $settings.stateDir } else { Join-Path $env:USERPROFILE '.ifileplus-connect' }
$statePath = [IO.Path]::GetFullPath($statePath)
$pidFile = Join-Path $statePath 'bridge.pid'
$bridgeFile = Join-Path $PSScriptRoot 'src\bridge.mjs'
$bundledNode = Join-Path $PSScriptRoot 'Runtime\node.exe'
$nodePath = if (Test-Path -LiteralPath $bundledNode) { $bundledNode } else { (Get-Command node -ErrorAction Stop).Source }
if (Test-Path -LiteralPath $pidFile) {
    $savedPid = [int](Get-Content -LiteralPath $pidFile -Raw)
    $old = Get-CimInstance Win32_Process -Filter "ProcessId=$savedPid"
    if ($old) {
        # A portable copy may refresh the existing bridge for the same configuration.
        $bridgeArguments = '\s+"[^"\r\n]+\\src\\bridge\.mjs"\s+"' + [regex]::Escape($configPath) + '"\s*$'
        if ($old.Name -ne 'node.exe' -or $old.CommandLine -notmatch $bridgeArguments) {
            throw '连接进程与当前配置不符，请检查原连接程序。'
        }
        if ($Restart -and !$old.CommandLine.Contains('"' + $bridgeFile + '"')) {
            throw '请从原目录停止连接程序，再从新目录启动。'
        }
        if ($EnsureRunning -and !$Restart) { return }
        if (!$Restart) {
            $qrPath = Join-Path $statePath 'pairing.png'
            $before = (Get-Item -LiteralPath $qrPath).LastWriteTimeUtc
            Set-Content -LiteralPath (Join-Path $statePath 'pairing-refresh.request') -Value 'refresh' -Encoding ASCII
            for ($n = 0; $n -lt 30; $n++) {
                Start-Sleep -Milliseconds 300
                if ((Get-Item -LiteralPath $qrPath).LastWriteTimeUtc -gt $before) {
                    Copy-Item -LiteralPath $qrPath -Destination (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Codex-Pairing.png') -Force
                    if (!$NoShowQR) { Start-Process powershell.exe -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"' + (Join-Path $PSScriptRoot 'show-pairing.ps1') + '"'),'-Config',('"' + $configPath + '"')) -WindowStyle Normal }
                    Write-Output 'Pairing QR refreshed. Existing connections were kept.'
                    return
                }
            }
            throw 'Refresh timed out. Run start.ps1 -Restart once to update the bridge.'
        }
        Stop-Process -Id $savedPid -ErrorAction Stop
        Start-Sleep -Milliseconds 500
    }
}
$credentialFile = Join-Path $statePath 'relay.token'
$env:IFILE_RELAY_TOKEN = (Get-Content -LiteralPath $credentialFile -Raw).Trim()
try {
    $ready = $false
    $process = Start-Process -FilePath $nodePath -ArgumentList @(('"' + $bridgeFile + '"'), ('"' + $configPath + '"')) -WorkingDirectory $PSScriptRoot -WindowStyle Hidden -RedirectStandardOutput (Join-Path $statePath 'bridge.log') -RedirectStandardError (Join-Path $statePath 'bridge-error.log') -PassThru
    Set-Content -LiteralPath $pidFile -Value $process.Id -Encoding ASCII
    for ($n = 0; $n -lt 30; $n++) {
        Start-Sleep -Milliseconds 500
        $process.Refresh()
        if ($process.HasExited) { throw "Bridge failed. See $statePath\bridge-error.log" }
        if ((Get-Content -LiteralPath (Join-Path $statePath 'bridge.log') -Raw -ErrorAction SilentlyContinue) -match 'pairing.png') { $ready = $true; break }
    }
    if (!$ready) { throw "Pairing was not ready within 15 seconds. See $statePath\bridge-error.log" }
    Copy-Item -LiteralPath (Join-Path $statePath 'pairing.png') -Destination (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Codex-Pairing.png') -Force
    Write-Output "Pairing QR (valid for 2 minutes): $statePath\pairing.png"
} finally { Remove-Item Env:IFILE_RELAY_TOKEN -ErrorAction SilentlyContinue }
if (!$NoShowQR) {
    $viewer = Join-Path $PSScriptRoot 'show-pairing.ps1'
    Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $viewer + '"'), '-Config', ('"' + $configPath + '"')) -WindowStyle Normal
}
