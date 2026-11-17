$ErrorActionPreference = 'Stop'
$connectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$buildRoot = [IO.Path]::GetFullPath((Join-Path $connectRoot '..\Build'))
[void][IO.Directory]::CreateDirectory($buildRoot)
$fixture = Join-Path $buildRoot ('InstallerEntryTest-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)

function Invoke-InstallerEntry {
    param([string]$Entry, [string]$WorkingDirectory)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $env:ComSpec
    $start.Arguments = '/d /c ""' + $Entry + '""'
    $start.WorkingDirectory = $WorkingDirectory
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    try {
        $process.StandardInput.WriteLine('')
        $process.StandardInput.Close()
        if (!$process.WaitForExit(10000)) {
            $process.Kill()
            throw 'Installer entry did not exit within 10 seconds.'
        }
        return [PSCustomObject]@{
            Code = $process.ExitCode
            Output = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
        }
    } finally { $process.Dispose() }
}

try {
    $entry = Join-Path $fixture '安装 AstroGate Connect.cmd'
    Copy-Item -LiteralPath (Join-Path $connectRoot '安装 AstroGate Connect.cmd') -Destination $entry
    $missing = Invoke-InstallerEntry -Entry $entry -WorkingDirectory $fixture
    if ($missing.Code -ne 1 -or $missing.Output -notmatch 'Extract All' -or $missing.Output -match 'install-app\.ps1.*does not exist') {
        throw ('Incomplete ZIP did not show the extraction guidance: ' + $missing.Output)
    }

    [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'Runtime'))
    [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'src'))
    [IO.File]::WriteAllText((Join-Path $fixture 'Runtime\node.exe'), '')
    [IO.File]::WriteAllText((Join-Path $fixture 'src\bridge.mjs'), '')
    [IO.File]::WriteAllText((Join-Path $fixture 'install-app.ps1'), "Write-Output 'INSTALL_ENTRY_REACHED'`r`nexit 0`r`n", [Text.Encoding]::ASCII)
    $complete = Invoke-InstallerEntry -Entry $entry -WorkingDirectory $fixture
    if ($complete.Code -ne 0 -or $complete.Output -notmatch 'INSTALL_ENTRY_REACHED') {
        throw ('Complete ZIP did not reach the installer: ' + $complete.Output)
    }
    Write-Output 'PASS: ZIP-preview launch explains full extraction; complete package reaches PowerShell installer'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    $allowed = [IO.Path]::GetFullPath($buildRoot).TrimEnd('\') + '\'
    if (!$resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path $resolved -Leaf) -notlike 'InstallerEntryTest-*') {
        throw 'Unexpected cleanup target'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
