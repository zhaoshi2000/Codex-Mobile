param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\AstroGate Connect'),
    [string]$ShortcutRoot = '',
    [switch]$NoLaunch,
    [switch]$NoProcessStop
)

$ErrorActionPreference = 'Stop'
$sourceRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$sameDirectory = [string]::Equals($sourceRoot, $InstallRoot, [StringComparison]::OrdinalIgnoreCase)
if (!$sameDirectory -and $InstallRoot.StartsWith($sourceRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw '安装位置不能位于解压目录内部。'
}
foreach ($name in @('Runtime\node.exe', 'src\bridge.mjs', 'open-connect.ps1', 'bootstrap.ps1')) {
    if (!(Test-Path -LiteralPath (Join-Path $sourceRoot $name) -PathType Leaf)) {
        throw "安装包不完整，缺少 $name。请先完整解压 ZIP。"
    }
}

$mutex = New-Object Threading.Mutex($false, 'Local\AstroGateConnectInstaller')
$locked = $false
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (!$locked) { throw '安装程序已经在运行。' }

    if (!$sameDirectory) {
        if (!$NoProcessStop -and (Test-Path -LiteralPath $InstallRoot)) {
            $oldWatchdog = Join-Path $InstallRoot 'watchdog.ps1'
            Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
                Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($oldWatchdog, [StringComparison]::OrdinalIgnoreCase) -ge 0 } |
                ForEach-Object { Stop-Process -Id $_.ProcessId -ErrorAction Stop }
            $oldStop = Join-Path $InstallRoot 'stop.ps1'
            $config = Join-Path $env:USERPROFILE '.ifileplus-connect\bridge.config.json'
            $pidFile = Join-Path $env:USERPROFILE '.ifileplus-connect\bridge.pid'
            if ((Test-Path -LiteralPath $oldStop) -and (Test-Path -LiteralPath $config) -and
                (Test-Path -LiteralPath $pidFile)) {
                & $oldStop -Config $config | Out-Null
            }
        }
        [void][IO.Directory]::CreateDirectory($InstallRoot)
        & robocopy.exe $sourceRoot $InstallRoot /E /COPY:DAT /DCOPY:DAT /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "复制程序文件失败（robocopy 退出码 $LASTEXITCODE）。" }

        # Preserve the extracted package so it can install another Windows PC.
        # bootstrap.ps1 imports and removes only the installed copy of the token.
        $sourceToken = Join-Path $sourceRoot 'setup\relay.token'
        $installedToken = Join-Path $InstallRoot 'setup\relay.token'
        if ((Test-Path -LiteralPath $sourceToken) -and (Test-Path -LiteralPath $installedToken)) {
            $sourceHash = (Get-FileHash -LiteralPath $sourceToken -Algorithm SHA256).Hash
            $installedHash = (Get-FileHash -LiteralPath $installedToken -Algorithm SHA256).Hash
            if ($sourceHash -ne $installedHash) { throw '安装后的连接凭据校验失败。' }
        }
    }

    $launcher = Join-Path $InstallRoot 'Open AstroGate Connect.cmd'
    if (!(Test-Path -LiteralPath $launcher -PathType Leaf)) { throw '安装后的启动程序不存在。' }
    if ($ShortcutRoot) {
        $desktop = Join-Path $ShortcutRoot 'Desktop'
        $startMenu = Join-Path $ShortcutRoot 'StartMenu'
    } else {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $startMenu = [Environment]::GetFolderPath('Programs')
    }
    $shell = New-Object -ComObject WScript.Shell
    foreach ($folder in @($desktop, $startMenu)) {
        [void][IO.Directory]::CreateDirectory($folder)
        $shortcut = $shell.CreateShortcut((Join-Path $folder 'AstroGate Connect.lnk'))
        $shortcut.TargetPath = $launcher
        $shortcut.WorkingDirectory = $InstallRoot
        $shortcut.IconLocation = (Join-Path $InstallRoot 'AstroGate.ico')
        $shortcut.Description = 'AstroGate Connect · 打开扫码配对'
        $shortcut.Save()
    }
    Write-Output "AstroGate Connect 已安装到 $InstallRoot"
    if (!$NoLaunch) {
        & (Join-Path $InstallRoot 'open-connect.ps1')
    }
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
