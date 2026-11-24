# Dot-source from Windows PowerShell 5.1 or newer. Never embeds a machine-specific path.
function Test-CodexExecutable {
    param([string]$Candidate)
    if (!$Candidate -or !(Test-Path -LiteralPath $Candidate -PathType Leaf)) { return $false }
    try {
        $version = & $Candidate --version 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }
        return (($version -join ' ') -match '^codex-cli\s+\S+')
    } catch { return $false }
}

function Find-CodexExecutable {
    param([string]$Preferred)
    $candidates = @()
    if ($Preferred) { $candidates += $Preferred }
    # The desktop may run a user-writable native CLI even when the packaged
    # WindowsApps copy is visible but cannot be executed by this account.
    $desktopBin = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    if (Test-Path -LiteralPath $desktopBin -PathType Container) {
        foreach ($directory in @(Get-ChildItem -LiteralPath $desktopBin -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
            $candidates += Join-Path $directory.FullName 'codex.exe'
        }
    }
    if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
        $packages = @(Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue | Sort-Object Version -Descending)
        foreach ($package in $packages) {
            $candidates += Join-Path $package.InstallLocation 'app\resources\codex.exe'
        }
    }
    # Standalone desktop installations, including a custom install directory while running.
    foreach ($process in @(Get-Process -Name Codex -ErrorAction SilentlyContinue)) {
        if ($process.Path) { $candidates += Join-Path (Split-Path $process.Path -Parent) 'resources\codex.exe' }
    }
    foreach ($base in @($env:LOCALAPPDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (!$base) { continue }
        foreach ($relative in @('Programs\Codex\resources\codex.exe', 'Codex\resources\codex.exe', 'Codex\app\resources\codex.exe')) {
            $candidates += Join-Path $base $relative
        }
    }
    $npmRoot = Join-Path $env:APPDATA 'npm\node_modules\@openai'
    foreach ($target in @('x86_64-pc-windows-msvc', 'aarch64-pc-windows-msvc')) {
        foreach ($package in @('codex-win32-x64', 'codex-win32-arm64')) {
            $candidates += Join-Path $npmRoot "codex\node_modules\@openai\$package\vendor\$target\bin\codex.exe"
            $candidates += Join-Path $npmRoot "$package\vendor\$target\bin\codex.exe"
        }
        $candidates += Join-Path $npmRoot "codex\vendor\$target\codex\codex.exe"
    }
    foreach ($candidate in $candidates) {
        if (Test-CodexExecutable -Candidate $candidate) { return $candidate }
    }
    # PATH may contain a CLI installation; the desktop application must still be running.
    $command = Get-Command codex.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and (Test-CodexExecutable -Candidate $command.Source)) { return $command.Source }
    return $null
}

function Test-CodexDesktopRunning {
    param([string]$CodexCli)
    $standalone = if ($CodexCli -and $CodexCli -match '\\resources\\codex\.exe$') {
        Join-Path (Split-Path (Split-Path $CodexCli -Parent) -Parent) 'Codex.exe'
    }
    foreach ($process in @(Get-Process -Name 'Codex','ChatGPT' -ErrorAction SilentlyContinue)) {
        if ($process.Path -match '[\\/]OpenAI\.Codex_[^\\/]+[\\/]app[\\/](ChatGPT|Codex)\.exe$' -or
            ($standalone -and $process.Path -eq $standalone)) { return $true }
    }
    return $false
}

function Start-CodexDesktop {
    param([string]$CodexCli, [switch]$Hidden)
    if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
        $packages = @(Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue | Sort-Object Version -Descending)
        foreach ($package in $packages) {
            try {
                $manifest = Get-AppxPackageManifest -Package $package.PackageFullName -ErrorAction Stop
                $app = @($manifest.Package.Applications.Application) |
                    Where-Object { $_.Executable -match '(ChatGPT|Codex)\.exe$' } |
                    Select-Object -First 1
                if (!$app) { continue }
                $activation = 'shell:AppsFolder\' + $package.PackageFamilyName + '!' + $app.Id
                if ($Hidden) { Start-Process -FilePath explorer.exe -ArgumentList $activation -WindowStyle Hidden }
                else { Start-Process -FilePath explorer.exe -ArgumentList $activation -WindowStyle Normal }
                return $true
            } catch { continue }
        }
    }
    if ($CodexCli -and $CodexCli -match '\\resources\\codex\.exe$') {
        $desktop = Join-Path (Split-Path (Split-Path $CodexCli -Parent) -Parent) 'Codex.exe'
        if (Test-Path -LiteralPath $desktop -PathType Leaf) {
            if ($Hidden) { Start-Process -FilePath $desktop -WindowStyle Hidden }
            else { Start-Process -FilePath $desktop -WindowStyle Normal }
            return $true
        }
    }
    return $false
}

function Repair-CodexExecutable {
    param([string]$ConfigPath)
    $settings = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $resolved = Find-CodexExecutable -Preferred $settings.codexExecutable
    if (!$resolved) { throw 'Codex executable not found. Install and open Codex Desktop, then run the launcher again.' }
    if ($resolved -ne $settings.codexExecutable) {
        $settings | Add-Member -NotePropertyName codexExecutable -NotePropertyValue $resolved -Force
        [IO.File]::WriteAllText($ConfigPath, ($settings | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
    }
}
