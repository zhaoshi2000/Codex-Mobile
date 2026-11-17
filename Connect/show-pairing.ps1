param([string]$Config = "$env:USERPROFILE\.ifileplus-connect\bridge.config.json")
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$settings = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json
$statePath = if ($settings.stateDir) { $settings.stateDir } else { Join-Path $env:USERPROFILE '.ifileplus-connect' }
$script:expires = [DateTimeOffset]::MinValue
$script:lastImageWrite = [DateTime]::MinValue
$background = [Drawing.ColorTranslator]::FromHtml('#101827')
$muted = [Drawing.ColorTranslator]::FromHtml('#9AAAC0')
$white = [Drawing.ColorTranslator]::FromHtml('#F7FAFF')
$accent = [Drawing.ColorTranslator]::FromHtml('#238BFF')

function New-TextLabel {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height,
          [float]$Size = 10, [Drawing.Color]$Color = [Drawing.Color]::White,
          [Drawing.FontStyle]$Style = [Drawing.FontStyle]::Regular)
    $label = New-Object Windows.Forms.Label
    $label.Text = $Text
    $label.SetBounds($X, $Y, $Width, $Height)
    $label.ForeColor = $Color
    $label.Font = [Drawing.Font]::new('Microsoft YaHei UI', $Size, $Style)
    return $label
}

$form = New-Object Windows.Forms.Form
$form.Text = 'AstroGate Connect · 电脑配对'
$form.ClientSize = New-Object Drawing.Size(780, 500)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.BackColor = $background
$form.AutoScaleMode = 'Dpi'
$form.Font = [Drawing.Font]::new('Microsoft YaHei UI', 10)
$iconPath = Join-Path $PSScriptRoot 'AstroGate.ico'
if (Test-Path -LiteralPath $iconPath -PathType Leaf) { $form.Icon = [Drawing.Icon]::new($iconPath) }

$brand = New-TextLabel 'AstroGate Connect' 28 24 340 42 20 $white ([Drawing.FontStyle]::Bold)
$subtitle = New-TextLabel '用手机扫描二维码，连接这台电脑' 30 69 340 28 10 $muted
$server = New-TextLabel '正在连接中转服务器…' 30 111 350 28 10 $muted
$divider = New-Object Windows.Forms.Panel
$divider.SetBounds(30, 151, 340, 1)
$divider.BackColor = [Drawing.ColorTranslator]::FromHtml('#29364A')
$stepsTitle = New-TextLabel '连接步骤' 30 174 340 32 13 $white ([Drawing.FontStyle]::Bold)
$step1 = New-TextLabel '01   打开手机 AstroGate 管家' 30 220 340 30 11 $white
$step2 = New-TextLabel '02   点击「连接」并添加设备' 30 267 340 30 11 $white
$step3 = New-TextLabel '03   扫描右侧配对二维码' 30 314 340 30 11 $white
$deviceCount = New-TextLabel '正在读取设备状态…' 30 382 340 27 10 $muted
$hint = New-TextLabel '关闭此窗口不会断开连接。' 30 423 340 42 9 $muted

$qrCard = New-Object Windows.Forms.Panel
$qrCard.SetBounds(411, 26, 340, 340)
$qrCard.BackColor = [Drawing.Color]::White
$picture = New-Object Windows.Forms.PictureBox
$picture.SetBounds(14, 14, 312, 312)
$picture.BackColor = [Drawing.Color]::White
$picture.SizeMode = 'Zoom'
$qrCard.Controls.Add($picture)

$countdown = New-TextLabel '正在生成配对码…' 411 378 340 30 10 $muted
$countdown.TextAlign = 'MiddleCenter'
$refresh = New-Object Windows.Forms.Button
$refresh.Text = '重新生成配对码'
$refresh.SetBounds(462, 427, 238, 42)
$refresh.FlatStyle = 'Flat'
$refresh.FlatAppearance.BorderSize = 0
$refresh.BackColor = $accent
$refresh.ForeColor = [Drawing.Color]::White
$refresh.Font = [Drawing.Font]::new('Microsoft YaHei UI', 10, [Drawing.FontStyle]::Bold)
$refresh.Cursor = [Windows.Forms.Cursors]::Hand
$form.Controls.AddRange(@($brand, $subtitle, $server, $divider, $stepsTitle,
    $step1, $step2, $step3, $deviceCount, $hint, $qrCard, $countdown, $refresh))

function Update-Pairing {
    $imagePath = Join-Path $statePath 'pairing.png'
    if (Test-Path -LiteralPath $imagePath -PathType Leaf) {
        $file = Get-Item -LiteralPath $imagePath
        if ($file.LastWriteTimeUtc -ne $script:lastImageWrite) {
            $uri = (Get-Content -LiteralPath (Join-Path $statePath 'pairing.txt') -Raw -Encoding UTF8).Trim()
            $encoded = [Uri]::UnescapeDataString(($uri -split 'data=', 2)[1]).Replace('-', '+').Replace('_', '/')
            $encoded = $encoded.PadRight($encoded.Length + ((4 - $encoded.Length % 4) % 4), '=')
            $pair = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json
            $script:expires = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$pair.expires)
            $stream = New-Object IO.MemoryStream(,[IO.File]::ReadAllBytes($file.FullName))
            $source = [Drawing.Image]::FromStream($stream)
            try { $bitmap = New-Object Drawing.Bitmap($source) }
            finally { $source.Dispose(); $stream.Dispose() }
            $previous = $picture.Image
            $picture.Image = $bitmap
            if ($previous) { $previous.Dispose() }
            $script:lastImageWrite = $file.LastWriteTimeUtc
        }
    }
    $statusFile = Join-Path $statePath 'connection-status.json'
    if (Test-Path -LiteralPath $statusFile -PathType Leaf) {
        $connection = Get-Content -LiteralPath $statusFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($connection.relayConnected) {
            $server.Text = '●   已连接中转服务器'
            $server.ForeColor = [Drawing.ColorTranslator]::FromHtml('#54D49A')
        } else {
            $server.Text = '●   中转暂未连接，正在自动重试'
            $server.ForeColor = [Drawing.ColorTranslator]::FromHtml('#F2C46D')
        }
        $deviceCount.Text = ('已配对 {0} 台手机  ·  当前连接 {1} 台' -f $connection.trustedPhones, $connection.connectedPhones)
    }
    $remaining = [Math]::Max(0, [Math]::Ceiling(($script:expires - [DateTimeOffset]::UtcNow).TotalSeconds))
    $picture.Visible = $remaining -gt 0
    if ($remaining -gt 0) {
        $countdown.Text = ('配对码剩余 {0} 秒' -f $remaining)
        $countdown.ForeColor = $muted
    } else {
        $countdown.Text = '配对码已过期，点击下方按钮刷新'
        $countdown.ForeColor = [Drawing.ColorTranslator]::FromHtml('#F2C46D')
    }
}

$refresh.Add_Click({
    $refresh.Enabled = $false
    $countdown.Text = '正在生成新的配对码…'
    [Windows.Forms.Application]::DoEvents()
    try {
        & (Join-Path $PSScriptRoot 'start.ps1') -Config $Config -NoShowQR | Out-Null
        Update-Pairing
    } catch {
        [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, '配对码生成失败')
    } finally { $refresh.Enabled = $true }
})
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({ try { Update-Pairing } catch { $countdown.Text = '正在等待配对码…' } })
$form.Add_Shown({ try { Update-Pairing } catch { $countdown.Text = '正在等待配对码…' }; $timer.Start(); $form.Activate() })
$form.Add_FormClosed({ $timer.Stop(); $timer.Dispose(); if ($picture.Image) { $picture.Image.Dispose() }; if ($form.Icon) { $form.Icon.Dispose() } })
[void]$form.ShowDialog()
$form.Dispose()
