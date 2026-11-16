# Dot-source from Windows PowerShell 5.1 or newer. Never embeds a machine-specific path.
function Find-CodexExecutable {
    param([string]$Preferred)
    if ($Preferred -and (Test-Path -LiteralPath $Preferred -PathType Leaf)) { return $Preferred }
    $candidates = @()
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
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    # PATH may contain a CLI installation; the desktop application must still be running.
    $command = Get-Command codex.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    return $null
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
