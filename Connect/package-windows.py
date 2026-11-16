"""Package an installed Connect tree and a clean official Node Windows x64 runtime."""
import argparse
import hashlib
from pathlib import Path
import shutil
import tempfile
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('--runtime', required=True, type=Path, help='Directory containing node.exe and LICENSE')
parser.add_argument('--version', default='0.4.24')
args = parser.parse_args()
if not all(c.isalnum() or c in '.-' for c in args.version):
    parser.error('Invalid version')
source = Path(__file__).resolve().parent
output_dir = source.parent / 'Build' / 'Releases'
output_dir.mkdir(parents=True, exist_ok=True)
output = output_dir / f'AstroGate-Connect-{args.version}-Windows-x64.zip'
with tempfile.TemporaryDirectory(prefix='astrogate-package-') as temp:
    stage = Path(temp) / 'AstroGate Connect'
    stage.mkdir()
    for name in ['src', 'node_modules']:
        shutil.copytree(source / name, stage / name)
    for name in ['Open AstroGate Connect.cmd', 'open-connect.ps1', 'find-codex.ps1',
                 'start.ps1', 'stop.ps1', 'show-pairing.ps1', 'README.md',
                 'THIRD_PARTY_NOTICES', 'package.json', 'package-lock.json']:
        shutil.copy2(source / name, stage / name)
    (stage / 'Runtime').mkdir()
    for name in ['node.exe', 'LICENSE']:
        shutil.copy2(args.runtime / name, stage / 'Runtime' / name)
    (stage / '使用说明.txt').write_text('''AstroGate Connect Windows x64

1. 在这台电脑安装、登录并打开 Codex 桌面版。
2. 将 ZIP 完整解压到任意可写目录；双击 Open AstroGate Connect.cmd。
3. 首次输入中转 WSS 地址与连接密钥。使用已有中转即可，无需再部署一台服务器。
   注意：这是中转连接密钥，不是 AI API Key。
4. 手机 AstroGate 管家 → 连接 → ＋ → 扫描电脑显示的二维码。

每台电脑各自生成身份和配对，手机可添加多台电脑。不要复制旧电脑的 .ifileplus-connect 目录。
无需另外安装 Node.js、Python 或开发工具；程序使用包内 Runtime。
配置仅保存在当前 Windows 用户目录，二维码不会复制到桌面。
支持商店版和常见独立安装目录；找不到时可手动选择桌面版 resources 下的 codex.exe。
更新 Codex 后，原 codex.exe 路径失效会重新查找。
此包用于 Windows x64，尚未验证 Windows ARM64、Mac 或 Linux。
电脑需要保持开机、联网且 Codex 正在运行；休眠或关机会断开连接。
关闭二维码窗口不会停止连接；在原包目录用 PowerShell 运行 ./stop.ps1 可停止连接。
更新旧电脑时先在旧包目录停止连接，再打开新包；原配对保留。
''', encoding='utf-8-sig')
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for file in sorted(stage.rglob('*')):
            if file.is_file():
                archive.write(file, file.relative_to(stage.parent))
with zipfile.ZipFile(output) as archive:
    assert archive.testzip() is None
    for name in archive.namelist():
        assert Path(name).name not in {'relay.token', 'bridge.config.json', 'device.json', 'pairing.png', 'pairing.txt'}
    for file in (source / 'src').glob('*.mjs'):
        assert archive.read('AstroGate Connect/src/' + file.name) == file.read_bytes()
digest = hashlib.sha256(output.read_bytes()).hexdigest()
output.with_suffix('.zip.sha256').write_text(f'{digest}  {output.name}\n', encoding='ascii')
print(output)
print(f'{output.stat().st_size} bytes; SHA256 {digest}')
