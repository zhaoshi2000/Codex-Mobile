$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\bootstrap.ps1')
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('astrogate-bootstrap-' + [Guid]::NewGuid().ToString('N'))
$install = Join-Path $fixture 'install'
$state = Join-Path $fixture 'state'
$setup = Join-Path $install 'setup'
$cli = Join-Path $fixture 'Codex\resources\codex.exe'
[void][IO.Directory]::CreateDirectory($setup)
[void][IO.Directory]::CreateDirectory((Split-Path $cli -Parent))
[IO.File]::WriteAllText($cli, '')
$firstToken = 'first-private-connect-key-0123456789abcdef'
$secondToken = 'second-private-connect-key-0123456789abcdef'
try {
    [IO.File]::WriteAllText((Join-Path $setup 'relay.token'), $firstToken)
    $configPath = Initialize-ConnectConfiguration -InstallRoot $install -StatePath $state -CodexExecutable $cli
    if ($configPath -ne (Join-Path $state 'bridge.config.json')) { throw 'Unexpected config location' }
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($config.relay -ne 'wss://1.14.93.149/ifile-connect') { throw 'Default relay missing' }
    if ($config.codexExecutable -ne $cli) { throw 'Codex path missing' }
    if ([IO.File]::ReadAllText((Join-Path $state 'relay.token')) -ne $firstToken) { throw 'Credential import failed' }
    if (Test-Path -LiteralPath (Join-Path $setup 'relay.token')) { throw 'Extracted credential was not deleted' }

    $legacyToken = 'legacy-secret-with-punctuation-!@#-0123456789'
    [IO.File]::WriteAllText((Join-Path $state 'relay.token'), $legacyToken)
    [IO.File]::WriteAllText((Join-Path $state 'device.json'), 'keep-device-identity')
    [IO.File]::WriteAllText((Join-Path $setup 'relay.token'), $secondToken)
    [void](Initialize-ConnectConfiguration -InstallRoot $install -StatePath $state)
    if ([IO.File]::ReadAllText((Join-Path $state 'relay.token')) -ne $legacyToken) { throw 'Existing credential was replaced' }
    if ([IO.File]::ReadAllText((Join-Path $state 'device.json')) -ne 'keep-device-identity') { throw 'Existing pairing was replaced' }
    if (Test-Path -LiteralPath (Join-Path $setup 'relay.token')) { throw 'Update package credential was not deleted' }

    $empty = Join-Path $fixture 'no-credentials'
    [void][IO.Directory]::CreateDirectory($empty)
    try {
        [void](Initialize-ConnectConfiguration -InstallRoot $empty -StatePath (Join-Path $fixture 'fresh') -CodexExecutable $cli)
        throw 'A public package unexpectedly configured a relay credential'
    } catch {
        if ($_.Exception.Message -notmatch '没有连接凭据') { throw }
    }
    Write-Output 'PASS: private credential import, default relay, setup cleanup, existing pairing preserved, public package rejected'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (!$resolved.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'astrogate-bootstrap-*') {
        throw 'Unexpected cleanup target'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
