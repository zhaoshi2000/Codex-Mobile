param([string]$Config = "$env:USERPROFILE\.ifileplus-connect\bridge.config.json")
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$settings = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json
$statePath = if ($settings.stateDir) { $settings.stateDir } else { Join-Path $env:USERPROFILE '.ifileplus-connect' }
$script:expires = [DateTimeOffset]::MinValue
$script:lastImageWrite = [DateTime]::MinValue
$form = New-Object Windows.Forms.Form
$form.Text = 'AstroGate Connect · 扫码连接'
$form.ClientSize = New-Object Drawing.Size(520, 640)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.BackColor = [Drawing.Color]::White
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 11)
$heading = New-Object Windows.Forms.Label
$heading.Text = '手机 AstroGate 管家 → Codex → ＋ → 扫码'
$heading.SetBounds(20, 15, 480, 35)
$heading.TextAlign = 'MiddleCenter'
$picture = New-Object Windows.Forms.PictureBox
$picture.SetBounds(35, 55, 450, 450)
$picture.SizeMode = 'Zoom'
$countdown = New-Object Windows.Forms.Label
$countdown.SetBounds(20, 515, 480, 30)
$countdown.TextAlign = 'MiddleCenter'
$note = New-Object Windows.Forms.Label
$note.Text = '有效期 2 分钟，仅限首次配对一部手机。已配对设备不受影响。'
$note.SetBounds(20, 548, 480, 42)
$note.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
$note.TextAlign = 'MiddleCenter'
$refresh = New-Object Windows.Forms.Button
$refresh.Text = '重新生成二维码'
$refresh.SetBounds(160, 592, 200, 34)
$form.Controls.AddRange(@($heading, $picture, $countdown, $note, $refresh))
function Update-Pairing {
    $file = Get-Item -LiteralPath (Join-Path $statePath 'pairing.png')
    if ($file.LastWriteTimeUtc -ne $script:lastImageWrite) {
        $uri = (Get-Content -LiteralPath (Join-Path $statePath 'pairing.txt') -Raw -Encoding UTF8).Trim()
        $encoded = [Uri]::UnescapeDataString(($uri -split 'data=', 2)[1]).Replace('-', '+').Replace('_', '/')
        $encoded = $encoded.PadRight($encoded.Length + ((4 - $encoded.Length % 4) % 4), '=')
        $pair = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json
        $script:expires = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$pair.expires)
        $stream = New-Object IO.MemoryStream(,[IO.File]::ReadAllBytes($file.FullName))
        $source = [Drawing.Image]::FromStream($stream)
        try { $bitmap = New-Object Drawing.Bitmap($source) } finally { $source.Dispose(); $stream.Dispose() }
        $previous = $picture.Image; $picture.Image = $bitmap
        if ($previous) { $previous.Dispose() }
        $script:lastImageWrite = $file.LastWriteTimeUtc
    }
    $statusFile = Join-Path $statePath 'connection-status.json'
    if (Test-Path -LiteralPath $statusFile) {
        $connection = Get-Content -LiteralPath $statusFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $note.Text = ('已配对 {0} 台 · 当前连接 {1} 台。二维码过期或关闭窗口不会断开连接。' -f $connection.trustedPhones, $connection.connectedPhones)
    }
    $remaining = [Math]::Max(0, [Math]::Ceiling(($script:expires - [DateTimeOffset]::UtcNow).TotalSeconds))
    $picture.Visible = $remaining -gt 0
    if ($remaining -gt 0) {
        $countdown.ForeColor = [Drawing.Color]::DarkGreen
        $countdown.Text = ('剩余 {0} 秒 · {1} 到期' -f $remaining, $script:expires.ToLocalTime().ToString('HH:mm:ss'))
    } else {
        $countdown.ForeColor = [Drawing.Color]::Firebrick
        $countdown.Text = '二维码已过期，请点击下方重新生成'
    }
}
$refresh.Add_Click({
    $refresh.Enabled = $false; $countdown.Text = '正在生成…'
    [Windows.Forms.Application]::DoEvents()
    try {
        & (Join-Path $PSScriptRoot 'start.ps1') -Config $Config -NoShowQR | Out-Null
        Update-Pairing
    } catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, '配对码生成失败') }
    finally { $refresh.Enabled = $true }
})
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({ try { Update-Pairing } catch { $countdown.Text = '正在等待配对二维码…' } })
$form.Add_Shown({ Update-Pairing; $timer.Start(); $form.Activate() })
$form.Add_FormClosed({ $timer.Stop(); $timer.Dispose(); if ($picture.Image) { $picture.Image.Dispose() } })
[void]$form.ShowDialog()
$form.Dispose()
