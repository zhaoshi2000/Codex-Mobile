$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\find-codex.ps1')
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('astrogate-portable-' + [Guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($fixture)
$originalLocalAppData = $env:LOCALAPPDATA
$originalAppData = $env:APPDATA
try {
    $env:LOCALAPPDATA = Join-Path $fixture 'Local'
    $env:APPDATA = Join-Path $fixture 'Roaming'
    $script:blocked = @()
    function Test-CodexExecutable {
        param([string]$Candidate)
        return ((Test-Path -LiteralPath $Candidate -PathType Leaf) -and ($Candidate -notin $script:blocked))
    }
    function Get-AppxPackage { param($Name) return $script:packages }
    function Get-Process { param($Name) return $script:processes }
    function Get-Command {
        param($Name, $CommandType)
        if ($Name -eq 'codex.exe') { return $script:pathCommand }
        return Microsoft.PowerShell.Core\Get-Command $Name
    }
    $script:packages = @()
    $script:processes = @()
    $script:pathCommand = $null
    $standalone = Join-Path $fixture 'Custom Install\resources\codex.exe'
    [void][IO.Directory]::CreateDirectory((Split-Path $standalone -Parent))
    [IO.File]::WriteAllText($standalone, '')
    if ((Find-CodexExecutable -Preferred $standalone) -ne $standalone) { throw 'Custom executable was not retained' }
    $store = Join-Path $fixture 'Store Update\app\resources\codex.exe'
    [void][IO.Directory]::CreateDirectory((Split-Path $store -Parent))
    [IO.File]::WriteAllText($store, '')
    $script:packages = @([pscustomobject]@{InstallLocation=(Join-Path $fixture 'Store Update');Version=[Version]'2.0'})
    if ((Find-CodexExecutable -Preferred (Join-Path $fixture 'removed.exe')) -ne $store) { throw 'Store update not found' }
    $config = Join-Path $fixture 'config.json'
    [IO.File]::WriteAllText($config, '{"codexExecutable":"missing.exe","name":"Other PC","codexHome":"custom-home","projects":[],"stateDir":"keep-pairing","relay":"wss://example.invalid"}')
    Repair-CodexExecutable -ConfigPath $config
    $saved = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
    if ($saved.codexExecutable -ne $store -or $saved.stateDir -ne 'keep-pairing' -or $saved.codexHome -ne 'custom-home' -or $saved.relay -ne 'wss://example.invalid') { throw 'Repair modified unrelated configuration' }
    $before = [IO.File]::ReadAllText($config)
    Repair-CodexExecutable -ConfigPath $config
    if ([IO.File]::ReadAllText($config) -ne $before) { throw 'Valid configuration was rewritten' }
    $cached = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin\cached\codex.exe'
    [void][IO.Directory]::CreateDirectory((Split-Path $cached -Parent))
    [IO.File]::WriteAllText($cached, '')
    $script:blocked = @($store)
    if ((Find-CodexExecutable -Preferred $store) -ne $cached) { throw 'Inaccessible Store CLI did not fall back to desktop cache' }
    Repair-CodexExecutable -ConfigPath $config
    $saved = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
    if ($saved.codexExecutable -ne $cached -or $saved.stateDir -ne 'keep-pairing') { throw 'Fallback did not preserve connection state' }
    Remove-Item -LiteralPath $cached -Force
    $npm = Join-Path $env:APPDATA 'npm\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe'
    [void][IO.Directory]::CreateDirectory((Split-Path $npm -Parent))
    [IO.File]::WriteAllText($npm, '')
    if ((Find-CodexExecutable -Preferred $store) -ne $npm) { throw 'Inaccessible Store CLI did not fall back to native npm CLI' }
    Remove-Item -LiteralPath $npm -Force
    $script:blocked = @()
    $script:packages = @()
    $script:processes = @([pscustomobject]@{Path=(Join-Path $fixture 'Custom Install\Codex.exe')})
    if ((Find-CodexExecutable) -ne $standalone) { throw 'Running standalone install not found' }
    $script:packages = @([pscustomobject]@{
        InstallLocation=(Join-Path $fixture 'Store Update')
        Version=[Version]'2.0'
        PackageFullName='OpenAI.Codex_fixture'
        PackageFamilyName='OpenAI.Codex_fixture'
    })
    function Get-AppxPackageManifest {
        param($Package)
        return [pscustomobject]@{Package=[pscustomobject]@{Applications=[pscustomobject]@{
            Application=@([pscustomobject]@{Id='App';Executable='app/ChatGPT.exe'})
        }}}
    }
    function Start-Process {
        param($FilePath, $ArgumentList, $WindowStyle)
        $script:desktopLaunch = [pscustomobject]@{FilePath=$FilePath;ArgumentList=$ArgumentList;WindowStyle=$WindowStyle}
    }
    if (!(Start-CodexDesktop -CodexCli $standalone -Hidden)) { throw 'Desktop activation failed' }
    if ($script:desktopLaunch.ArgumentList -ne 'shell:AppsFolder\OpenAI.Codex_fixture!App' -or
        $script:desktopLaunch.FilePath -ne 'explorer.exe') { throw 'Desktop activation used the CLI path' }
    # Check every shipped PowerShell script with the actual Windows PowerShell parser.
    foreach ($file in Get-ChildItem (Join-Path $PSScriptRoot '..') -Filter '*.ps1') {
        $tokens = $null; $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw ($errors | Out-String) }
    }
    Write-Output 'PASS: existing path, Store relocation, inaccessible Store and npm fallback, desktop activation, preserved settings, idempotence, PowerShell syntax'
} finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    $env:APPDATA = $originalAppData
    $resolved = [IO.Path]::GetFullPath($fixture)
    $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (!$resolved.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'astrogate-portable-*') { throw 'Unexpected cleanup target' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
