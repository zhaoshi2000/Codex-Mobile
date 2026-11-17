$ErrorActionPreference = 'Stop'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('astrogate-install-test-' + [Guid]::NewGuid())
$package = Join-Path $fixture 'Package'
$installed = Join-Path $fixture 'Installed'
$shortcuts = Join-Path $fixture 'Shortcuts'
[void][IO.Directory]::CreateDirectory((Join-Path $package 'Runtime'))
[void][IO.Directory]::CreateDirectory((Join-Path $package 'src'))
[void][IO.Directory]::CreateDirectory((Join-Path $package 'setup'))
try {
    $root = Split-Path $PSScriptRoot -Parent
    foreach ($name in @('install-app.ps1', 'install-autostart.ps1', 'watchdog.ps1',
                        'open-connect.ps1', 'bootstrap.ps1',
                        'Open AstroGate Connect.cmd', 'AstroGate.ico')) {
        Copy-Item -LiteralPath (Join-Path $root $name) -Destination (Join-Path $package $name)
    }
    [IO.File]::WriteAllText((Join-Path $package 'Runtime\node.exe'), 'fixture')
    [IO.File]::WriteAllText((Join-Path $package 'src\bridge.mjs'), 'fixture')
    $dummyToken = 'installation-fixture-token-12345678901234567890'
    [IO.File]::WriteAllText((Join-Path $package 'setup\relay.token'), $dummyToken)
    & (Join-Path $package 'install-app.ps1') -InstallRoot $installed -ShortcutRoot $shortcuts -NoLaunch -NoProcessStop | Out-Null
    if (!(Test-Path -LiteralPath (Join-Path $installed 'Runtime\node.exe'))) { throw 'Runtime was not installed' }
    if (!(Test-Path -LiteralPath (Join-Path $installed 'AstroGate.ico'))) { throw 'App icon was not installed' }
    if ((Get-Content -LiteralPath (Join-Path $installed 'setup\relay.token') -Raw) -ne $dummyToken) { throw 'Private setup token was not copied' }
    if (Test-Path -LiteralPath (Join-Path $package 'setup\relay.token')) { throw 'Extracted setup token was not removed' }
    & (Join-Path $package 'install-app.ps1') -InstallRoot $installed -ShortcutRoot $shortcuts -NoLaunch -NoProcessStop | Out-Null
    if ((Get-Content -LiteralPath (Join-Path $installed 'setup\relay.token') -Raw) -ne $dummyToken) { throw 'Reinstall erased private setup token' }
    $shell = New-Object -ComObject WScript.Shell
    foreach ($folder in @('Desktop', 'StartMenu')) {
        $linkPath = Join-Path (Join-Path $shortcuts $folder) 'AstroGate Connect.lnk'
        if (!(Test-Path -LiteralPath $linkPath)) { throw "Missing $folder shortcut" }
        $link = $shell.CreateShortcut($linkPath)
        if ($link.TargetPath -ne (Join-Path $installed 'Open AstroGate Connect.cmd')) { throw "Invalid $folder shortcut" }
    }
    $startup = Join-Path $fixture 'Startup'
    & (Join-Path $installed 'install-autostart.ps1') -Config (Join-Path $fixture 'config.json') -RegisterOnly -StartupRoot $startup | Out-Null
    $startupLink = Join-Path $startup 'AstroGate Connect.lnk'
    if (!(Test-Path -LiteralPath $startupLink)) { throw 'Missing startup shortcut' }
    $startupTarget = $shell.CreateShortcut($startupLink)
    if ($startupTarget.Arguments.IndexOf((Join-Path $installed 'watchdog.ps1'), [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw 'Startup shortcut does not use the installed watchdog'
    }
    Write-Output 'PASS: isolated app install, copied runtime and private setup, removed extracted token, created shortcuts and login startup'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (!$resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path $resolved -Leaf) -notlike 'astrogate-install-test-*') { throw 'Unexpected cleanup target' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
