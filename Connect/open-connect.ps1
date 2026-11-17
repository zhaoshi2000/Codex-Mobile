param([switch]$Configure)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'find-codex.ps1')
. (Join-Path $PSScriptRoot 'bootstrap.ps1')
Add-Type -AssemblyName System.Windows.Forms
[Windows.Forms.Application]::EnableVisualStyles()

function Select-CodexExecutable {
    $cli = Find-CodexExecutable
    if ($cli) { return $cli }
    $picker = New-Object Windows.Forms.OpenFileDialog
    try {
        $picker.Title = '选择 Codex 桌面版随附的 codex.exe'
        $picker.Filter = 'Codex (codex.exe)|codex.exe'
        if ($picker.ShowDialog() -ne 'OK') { return $null }
        return $picker.FileName
    } finally { $picker.Dispose() }
}

function Wait-CodexDesktop {
    param([string]$Cli)
    $pipe = '\\.\pipe\codex-ipc'
    if (Test-Path -LiteralPath $pipe) { return }
    $desktop = Join-Path (Split-Path (Split-Path $Cli -Parent) -Parent) 'Codex.exe'
    if (Test-Path -LiteralPath $desktop -PathType Leaf) {
        Start-Process -FilePath $desktop -WindowStyle Normal
    } else {
        throw '找不到 Codex 桌面版。请先安装并登录 Codex，然后重新打开连接程序。'
    }
    for ($n = 0; $n -lt 60; $n++) {
        if (Test-Path -LiteralPath $pipe) { return }
        Start-Sleep -Milliseconds 500
    }
    throw 'Codex 桌面版尚未就绪。请在打开的 Codex 窗口完成登录，然后重试。'
}

$statePath = Join-Path $env:USERPROFILE '.ifileplus-connect'
$configPath = Join-Path $statePath 'bridge.config.json'
$mutex = New-Object Threading.Mutex($false, 'Local\AstroGateConnectLauncher')
$locked = $false
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (!$locked) { return }
    if ($Configure -and (Test-Path -LiteralPath $configPath)) {
        $savedSettings = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $savedStatePath = if ($savedSettings.stateDir) { $savedSettings.stateDir } else { $statePath }
        $pidFile = Join-Path $savedStatePath 'bridge.pid'
        if (Test-Path -LiteralPath $pidFile) {
            $savedPid = [int](Get-Content -LiteralPath $pidFile -Raw)
            $running = Get-CimInstance Win32_Process -Filter "ProcessId=$savedPid"
            if ($running -and $running.Name -eq 'node.exe' -and $running.CommandLine -match '\\src\\bridge\.mjs') {
                throw '请先停止当前连接程序，再修改配置。'
            }
        }
    }
    $needsConfig = $Configure -or !(Test-Path -LiteralPath $configPath)
    $cli = if ($needsConfig) { Select-CodexExecutable } else { $null }
    if ($needsConfig -and !$cli) { return }
    $configPath = Initialize-ConnectConfiguration -InstallRoot $PSScriptRoot -StatePath $statePath -CodexExecutable $cli -Reconfigure:$Configure
    Repair-CodexExecutable -ConfigPath $configPath
    $settings = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Wait-CodexDesktop -Cli $settings.codexExecutable
    & (Join-Path $PSScriptRoot 'start.ps1') -Config $configPath
    & (Join-Path $PSScriptRoot 'install-autostart.ps1') -Config $configPath | Out-Null
} catch {
    $message = "连接程序启动失败。请确认 Codex 桌面版已打开并完成登录。`n`n" + $_.Exception.Message
    [void][Windows.Forms.MessageBox]::Show($message, 'AstroGate Connect')
    exit 2
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
