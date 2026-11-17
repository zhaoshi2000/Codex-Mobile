"""Guard against Windows PowerShell 5.1 corrupting Chinese text in the ZIP."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


CONNECT = Path(__file__).resolve().parents[1]
SCRIPTS = (
    'open-connect.ps1', 'bootstrap.ps1', 'find-codex.ps1',
    'start.ps1', 'stop.ps1', 'show-pairing.ps1',
    'install-app.ps1', 'install-autostart.ps1', 'watchdog.ps1',
)


class PackageEncodingTests(unittest.TestCase):
    def test_shipped_scripts_are_decodable_on_windows_powershell_51(self):
        for name in SCRIPTS:
            with self.subTest(name=name):
                data = (CONNECT / name).read_bytes()
                if any(byte > 127 for byte in data):
                    self.assertTrue(data.startswith(b'\xef\xbb\xbf'), name)
                data.decode('utf-8-sig')

    def assert_rejected(self, content, expected):
        build = CONNECT.parent / 'Build'
        build.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='encoding-test-', dir=build) as temp:
            fixture = Path(temp)
            source = fixture / 'Connect'
            source.mkdir()
            shutil.copy2(CONNECT / 'package-windows.py', source / 'package-windows.py')
            for name in SCRIPTS:
                (source / name).write_bytes(b'Write-Output OK\r\n')
            (source / 'open-connect.ps1').write_bytes(content)
            runtime = fixture / 'Runtime'
            runtime.mkdir()
            for name in ('node.exe', 'LICENSE'):
                (runtime / name).write_bytes(b'fixture')
            result = subprocess.run(
                [sys.executable, str(source / 'package-windows.py'), '--runtime', str(runtime)],
                text=True, capture_output=True, encoding='utf-8', errors='replace',
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(expected, result.stderr)
            self.assertFalse((fixture / 'Build' / 'Releases').exists())

    def test_packager_rejects_chinese_without_bom(self):
        self.assert_rejected('throw "中文错误"\r\n'.encode('utf-8'),
                             'open-connect.ps1 contains non-ASCII text without a UTF-8 BOM')

    def test_packager_rejects_invalid_utf8_after_bom(self):
        self.assert_rejected(b'\xef\xbb\xbf\xff',
                             'open-connect.ps1 has invalid UTF-8 after its BOM')


if __name__ == '__main__':
    unittest.main()
