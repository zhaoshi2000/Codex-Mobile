"""Package an installed Connect tree and a clean official Node Windows x64 runtime."""
import argparse
import hashlib
from pathlib import Path
import shutil
import tempfile
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('--runtime', required=True, type=Path, help='Directory containing node.exe and LICENSE')
parser.add_argument('--version', default='0.4.38')
parser.add_argument('--setup-token-file', type=Path,
                    help='Private 32+ character relay connection token. Never commit this file.')
args = parser.parse_args()
if not all(c.isalnum() or c in '.-' for c in args.version):
    parser.error('Invalid version')
for name in ('node.exe', 'LICENSE'):
    if not (args.runtime / name).is_file():
        parser.error(f'Runtime is missing {name}')
setup_token = None
if args.setup_token_file:
    if not args.setup_token_file.is_file():
        parser.error('Setup token file does not exist')
    setup_token = args.setup_token_file.read_text(encoding='utf-8-sig').strip()
    if not 32 <= len(setup_token) <= 512 or any(char.isspace() for char in setup_token):
        parser.error('Setup token must be 32–512 characters with no whitespace')
source = Path(__file__).resolve().parent
power_shell_scripts = [
    'open-connect.ps1', 'bootstrap.ps1', 'find-codex.ps1',
    'start.ps1', 'stop.ps1', 'show-pairing.ps1',
    'install-app.ps1', 'install-autostart.ps1', 'watchdog.ps1',
]

def check_powershell_encoding(name, content):
    """PowerShell 5.1 reads BOM-less scripts with the machine's ANSI code page."""
    if content.startswith(b'\xef\xbb\xbf'):
        try:
            content.decode('utf-8-sig')
        except UnicodeDecodeError:
            parser.error(f'{name} has invalid UTF-8 after its BOM')
    elif any(byte > 127 for byte in content):
        parser.error(f'{name} contains non-ASCII text without a UTF-8 BOM; '
                     'Windows PowerShell 5.1 may misread Chinese and break syntax')

for name in power_shell_scripts:
    script = source / name
    if not script.is_file():
        parser.error(f'Missing {name}')
    check_powershell_encoding(name, script.read_bytes())

output_dir = source.parent / 'Build' / 'Releases'
output_dir.mkdir(parents=True, exist_ok=True)
kind = '-Private' if setup_token else ''
output = output_dir / f'AstroGate-Connect-{args.version}{kind}-Windows-x64.zip'
with tempfile.TemporaryDirectory(prefix='astrogate-package-') as temp:
    stage = Path(temp) / 'AstroGate Connect'
    stage.mkdir()
    for name in ['src', 'node_modules']:
        shutil.copytree(source / name, stage / name)
    for name in ['安装 AstroGate Connect.cmd', 'AstroGate.ico',
                 'Open AstroGate Connect.cmd', *power_shell_scripts, 'README.md',
                 'THIRD_PARTY_NOTICES', 'package.json', 'package-lock.json']:
        shutil.copy2(source / name, stage / name)
    (stage / 'Runtime').mkdir()
    for name in ['node.exe', 'LICENSE']:
        shutil.copy2(args.runtime / name, stage / 'Runtime' / name)
    if setup_token:
        setup_dir = stage / 'setup'
        setup_dir.mkdir()
        (setup_dir / 'relay.token').write_text(setup_token, encoding='utf-8')
    setup_note = ('此私人安装包包含专用中转密钥，首次运行自动导入。解压目录保留密钥以便安装其他电脑；使用后请删除解压目录，不要公开分享 ZIP。'
                  if setup_token else '此公开安装包不含连接密钥，首次运行需从中转后台取得专用密钥。')
    (stage / '使用说明.txt').write_text(f'''AstroGate Connect Windows x64

1. 在这台电脑安装、登录并打开 Codex 桌面版。
2. 解压 ZIP 后双击“安装 AstroGate Connect.cmd”，程序会安装到当前用户目录，并创建开始菜单、桌面和登录自启入口。
3. 安装完成会自动打开配对二维码；手机 AstroGate 管家 → 连接 → ＋ → 扫码。
4. 重启电脑并登录 Windows 后，连接会自动恢复，原配对保留；重新打开程序可添加其他手机。

{setup_note}

每台电脑各自生成身份和配对，手机可添加多台电脑。不要复制旧电脑的 .ifileplus-connect 目录。
无需另外安装 Node.js、Python 或开发工具；程序使用包内 Runtime。
配置仅保存在当前 Windows 用户目录，二维码不会复制到桌面。
支持商店版和常见独立安装目录；找不到时可手动选择桌面版 resources 下的 codex.exe。
更新 Codex 后，原 codex.exe 路径失效会重新查找。
此包用于 Windows x64，尚未验证 Windows ARM64、Mac 或 Linux。
电脑需要保持开机、联网且 Codex 正在运行；休眠或关机会断开连接。
关闭二维码窗口不会停止连接；停用自启及停止连接的方法见 README.md。
更新旧电脑时再次运行安装器；原配对和用户配置保留。
''', encoding='utf-8-sig')
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for file in sorted(stage.rglob('*')):
            if file.is_file():
                archive.write(file, file.relative_to(stage.parent))
with zipfile.ZipFile(output) as archive:
    assert archive.testzip() is None
    setup_name = 'AstroGate Connect/setup/relay.token'
    assert (setup_name in archive.namelist()) == (setup_token is not None)
    if setup_token:
        assert archive.read(setup_name).decode('utf-8') == setup_token
    for name in archive.namelist():
        if name != setup_name:
            assert Path(name).name not in {'relay.token', 'bridge.config.json', 'device.json', 'pairing.png', 'pairing.txt'}
    for file in (source / 'src').glob('*.mjs'):
        assert archive.read('AstroGate Connect/src/' + file.name) == file.read_bytes()
    for name in power_shell_scripts:
        bundled = archive.read('AstroGate Connect/' + name)
        assert bundled == (source / name).read_bytes(), name
        check_powershell_encoding(name, bundled)
digest = hashlib.sha256(output.read_bytes()).hexdigest()
output.with_suffix('.zip.sha256').write_text(f'{digest}  {output.name}\n', encoding='ascii')
print(output)
print(f'{output.stat().st_size} bytes; SHA256 {digest}')
