#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ifile-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/Sources/FileServices" "$TEST_DIR/Tests/FileServicesTests/Fixtures"
cp "$ROOT/iFilePlus/Services/CodexDictationSession.swift" "$ROOT/iFilePlus/Services/CodexNavigationCache.swift" "$ROOT/iFilePlus/Services/CodexThumbnailCache.swift" "$ROOT/iFilePlus/Services/CodexDownloadState.swift" "$ROOT/iFilePlus/Services/CodexChatTimeline.swift" "$ROOT/iFilePlus/Services/ServerAIProtocol.swift" "$ROOT/iFilePlus/Services/OpenClawProtocol.swift" "$ROOT/iFilePlus/Services/ChatMarkdown.swift" "$ROOT/iFilePlus/Services/ArchiveService.swift" "$ROOT/iFilePlus/Services/LocalFileService.swift" "$TEST_DIR/Sources/FileServices/"
cp "$ROOT/Tests/FileServicesTests.swift" "$TEST_DIR/Tests/FileServicesTests/"
cat > "$TEST_DIR/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "FileServices", platforms: [.macOS(.v13)], dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")], targets: [.target(name: "FileServices", dependencies: ["ZIPFoundation"]), .testTarget(name: "FileServicesTests", dependencies: ["FileServices"], resources: [.copy("Fixtures")])])
SWIFT
python3 - "$TEST_DIR/Tests/FileServicesTests/Fixtures" <<'PY'
from pathlib import Path
import sys,zipfile,stat,warnings
p=Path(sys.argv[1])
with zipfile.ZipFile(p/'normal.zip','w',zipfile.ZIP_DEFLATED) as z:z.writestr('nested/content.unknown','测试文本\n')
with zipfile.ZipFile(p/'traversal.zip','w') as z:z.writestr('../escape.txt','escape')
with zipfile.ZipFile(p/'symlink.zip','w') as z:
 i=zipfile.ZipInfo('link');i.create_system=3;i.external_attr=(stat.S_IFLNK|0o777)<<16;z.writestr(i,'../outside')
with warnings.catch_warnings():
 warnings.simplefilter('ignore')
 with zipfile.ZipFile(p/'duplicate.zip','w') as z:z.writestr('file','first');z.writestr('file','second')
with zipfile.ZipFile(p/'corrupt.zip','w') as z:z.writestr('text','original-content')
b=(p/'corrupt.zip').read_bytes().replace(b'original-content',b'corrupt!-content');(p/'corrupt.zip').write_bytes(b)
PY
cd "$TEST_DIR"
swift test --parallel
