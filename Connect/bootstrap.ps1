# Dot-source from the Windows launcher. The public package never contains a relay key.
$script:AstroGateDefaultRelay = 'wss://1.14.93.149/ifile-connect'

function Set-ConnectPrivateFileAcl {
    param([Parameter(Mandatory)][string]$Path)
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $rule = New-Object Security.AccessControl.FileSystemAccessRule($user, [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow)
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Initialize-ConnectConfiguration {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$StatePath,
        [string]$CodexExecutable,
        [switch]$Reconfigure
    )
    $StatePath = [IO.Path]::GetFullPath($StatePath)
    $configPath = Join-Path $StatePath 'bridge.config.json'
    $settings = if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } else { $null }
    $effectiveStatePath = if ($settings -and $settings.stateDir) {
        [IO.Path]::GetFullPath($settings.stateDir)
    } else { $StatePath }
    $tokenPath = Join-Path $effectiveStatePath 'relay.token'
    $setupPath = Join-Path $InstallRoot 'setup\relay.token'
    $needsToken = !(Test-Path -LiteralPath $tokenPath -PathType Leaf)
    if ($needsToken -and !(Test-Path -LiteralPath $setupPath -PathType Leaf)) {
        throw '此安装包没有连接凭据。请使用管理员提供的私人安装包（包含 setup\relay.token）。'
    }
    $token = if ($needsToken) { [IO.File]::ReadAllText($setupPath).Trim() }
             else { [IO.File]::ReadAllText($tokenPath).Trim() }
    if ($token.Length -lt 32 -or $token.Length -gt 512 -or $token -match '[\r\n]') {
        throw '中转连接凭据无效，请重新获取私人安装包。'
    }
    if ($needsToken) {
        [void][IO.Directory]::CreateDirectory($effectiveStatePath)
        $temp = Join-Path $effectiveStatePath ('.relay-token-' + [Guid]::NewGuid().ToString('N'))
        try {
            [IO.File]::WriteAllText($temp, $token, (New-Object Text.UTF8Encoding($false)))
            Set-ConnectPrivateFileAcl -Path $temp
            [IO.File]::Move($temp, $tokenPath)
        } finally {
            if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
        }
    }
    # The user's state directory now owns the secret. Remove the extracted copy.
    if (Test-Path -LiteralPath $setupPath -PathType Leaf) {
        Remove-Item -LiteralPath $setupPath -Force
    }

    if (!$settings -or $Reconfigure) {
        if (!$CodexExecutable -or !(Test-Path -LiteralPath $CodexExecutable -PathType Leaf)) {
            throw '请先安装并打开 Codex 桌面版，然后重新启动 AstroGate Connect。'
        }
        if ($settings) {
            $settings | Add-Member -NotePropertyName relay -NotePropertyValue $script:AstroGateDefaultRelay -Force
            $settings | Add-Member -NotePropertyName codexExecutable -NotePropertyValue $CodexExecutable -Force
            $config = $settings
        } else {
            $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
            $config = [ordered]@{
                name = $env:COMPUTERNAME
                relay = $script:AstroGateDefaultRelay
                codexExecutable = $CodexExecutable
                codexHome = $codexHome
                desktopCatalog = $true
                projects = @()
            }
        }
        [void][IO.Directory]::CreateDirectory($StatePath)
        [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
    }
    return $configPath
}
