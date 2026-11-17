param([switch]$Configure)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'find-codex.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

function New-ConnectionSettings {
    $cli = Find-CodexExecutable
    if (!$cli) {
        $picker = New-Object Windows.Forms.OpenFileDialog
        try {
            $picker.Title = '选择 Codex 桌面版随附的 codex.exe'
            $picker.Filter = 'Codex (codex.exe)|codex.exe'
            if ($picker.ShowDialog() -ne 'OK') { return }
            $cli = $picker.FileName
        } finally { $picker.Dispose() }
    }

    $form = New-Object Windows.Forms.Form
    try {
        $form.Text = 'AstroGate Connect · 首次设置'
        $form.ClientSize = New-Object Drawing.Size(480, 220)
        $form.StartPosition = 'CenterScreen'
        $form.FormBorderStyle = 'FixedDialog'
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false
        $form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10)
        $note = New-Object Windows.Forms.Label
        $note.Text = '请先打开并登录 Codex 桌面版。从中转后台复制 WSS 地址和连接密钥；后台登录凭据不要填在这里。'
        $note.SetBounds(16, 10, 448, 44)
        $relayLabel = New-Object Windows.Forms.Label
        $relayLabel.Text = '中转地址（wss://）'
        $relayLabel.SetBounds(16, 60, 448, 22)
        $relay = New-Object Windows.Forms.TextBox
        $relay.SetBounds(16, 84, 448, 26)
        $tokenLabel = New-Object Windows.Forms.Label
        $tokenLabel.Text = '连接密钥'
        $tokenLabel.SetBounds(16, 117, 448, 22)
        $token = New-Object Windows.Forms.TextBox
        $token.UseSystemPasswordChar = $true
        $token.SetBounds(16, 141, 448, 26)
        $connect = New-Object Windows.Forms.Button
        $connect.Text = '保存并连接'
        $connect.SetBounds(344, 179, 120, 30)
        $connect.Add_Click({
            $address = $null
            if (![Uri]::TryCreate($relay.Text.Trim(), [UriKind]::Absolute, [ref]$address) -or $address.Scheme -ne 'wss' -or !$address.Host -or $address.UserInfo) {
                [void][Windows.Forms.MessageBox]::Show($form, '请输入中转服务器的 wss:// 地址。', '请检查中转地址')
            } elseif ($token.Text.Trim().Length -lt 32) {
                [void][Windows.Forms.MessageBox]::Show($form, '连接密钥至少需要 32 个字符。', '请检查连接密钥')
            } else { $form.DialogResult = 'OK' }
        })
        $form.AcceptButton = $connect
        $form.Controls.AddRange(@($note, $relayLabel, $relay, $tokenLabel, $token, $connect))
        if ($form.ShowDialog() -ne 'OK') { return }

        $codexDir = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
        $config = [ordered]@{
            name = $env:COMPUTERNAME
            relay = $relay.Text.Trim()
            codexExecutable = $cli
            codexHome = $codexDir
            desktopCatalog = $true
            projects = @()
        }
        [void][IO.Directory]::CreateDirectory($statePath)
        $encoding = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText((Join-Path $statePath 'relay.token'), $token.Text.Trim(), $encoding)
        [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json), $encoding)
        return $true
    } finally { $form.Dispose() }
}

$statePath = Join-Path $env:USERPROFILE '.ifileplus-connect'
$configPath = Join-Path $statePath 'bridge.config.json'
$mutex = New-Object Threading.Mutex($false, 'Local\AstroGateConnectLauncher')
try {
    $locked = $false
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (!$locked) { return }
    if ($Configure -and (Test-Path -LiteralPath $configPath)) {
        $savedSettings = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $savedStatePath = if ($savedSettings.stateDir) { $savedSettings.stateDir } else { $statePath }
        $pidFile = Join-Path $savedStatePath 'bridge.pid'
        if (Test-Path -LiteralPath $pidFile) {
            $savedPid = [int](Get-Content -LiteralPath $pidFile -Raw)
            if (Get-Process -Id $savedPid -ErrorAction SilentlyContinue) {
                throw '请先停止当前连接程序，再修改中转配置。'
            }
        }
    }
    if ($Configure -or !(Test-Path -LiteralPath $configPath)) {
        if (!(New-ConnectionSettings)) { return }
    }
    if (!(Test-Path -LiteralPath $configPath)) { return }
    & (Join-Path $PSScriptRoot 'start.ps1') -Config $configPath
    & (Join-Path $PSScriptRoot 'install-autostart.ps1') -Config $configPath | Out-Null
} catch {
    $message = "请确认 Codex 桌面版已登录并在运行，中转服务可用。`n`n" + $_.Exception.Message
    [void][Windows.Forms.MessageBox]::Show($message, 'AstroGate Connect 启动失败')
    exit 1
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
