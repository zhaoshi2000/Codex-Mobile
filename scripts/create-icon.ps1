Add-Type -AssemblyName System.Drawing
$dest = Join-Path $PSScriptRoot '..\iFilePlus\Assets.xcassets'
$bitmap = [System.Drawing.Bitmap]::new(1024,1024,[System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$g = [System.Drawing.Graphics]::FromImage($bitmap)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush ([System.Drawing.Point]::new(0,0)),([System.Drawing.Point]::new(1024,1024)),([System.Drawing.ColorTranslator]::FromHtml('#162D54')),([System.Drawing.ColorTranslator]::FromHtml('#080F24'))
$g.FillRectangle($bg,0,0,1024,1024)
$portal = New-Object System.Drawing.Drawing2D.GraphicsPath
$portal.AddLine(260,766,260,398)
$portal.AddBezier(260,398,260,282,372,208,512,208)
$portal.AddBezier(512,208,652,208,764,282,764,398)
$portal.AddLine(764,398,764,766)
$brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush ([System.Drawing.Point]::new(250,200)),([System.Drawing.Point]::new(770,780)),([System.Drawing.ColorTranslator]::FromHtml('#69E6F2')),([System.Drawing.ColorTranslator]::FromHtml('#3478F6'))
$brush.WrapMode = [System.Drawing.Drawing2D.WrapMode]::TileFlipXY
$pen = New-Object System.Drawing.Pen $brush,64
$pen.StartCap = $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
$g.DrawPath($pen,$portal)
$white = New-Object System.Drawing.Pen ([System.Drawing.Color]::White),46
$white.StartCap = $white.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
$white.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
$chevron = [System.Drawing.Point[]]@([System.Drawing.Point]::new(386,458),[System.Drawing.Point]::new(478,540),[System.Drawing.Point]::new(386,622))
$g.DrawLines($white,$chevron)
$g.DrawLine($white,551,622,641,622)
$star = [System.Drawing.Point[]]@([System.Drawing.Point]::new(797,160),[System.Drawing.Point]::new(817,218),[System.Drawing.Point]::new(875,238),[System.Drawing.Point]::new(817,258),[System.Drawing.Point]::new(797,316),[System.Drawing.Point]::new(777,258),[System.Drawing.Point]::new(719,238),[System.Drawing.Point]::new(777,218))
$g.FillPolygon([System.Drawing.Brushes]::White,$star)
$bitmap.Save((Join-Path $dest 'AppIcon.appiconset\AppIcon-1024.png'),[System.Drawing.Imaging.ImageFormat]::Png)
New-Item -ItemType Directory -Path (Join-Path $dest 'AstroGateLogo.imageset') -Force | Out-Null
$bitmap.Save((Join-Path $dest 'AstroGateLogo.imageset\AstroGateLogo.png'),[System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose();$bitmap.Dispose();$bg.Dispose();$portal.Dispose();$brush.Dispose();$pen.Dispose();$white.Dispose()
