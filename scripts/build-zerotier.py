#!/usr/bin/env python3
"""Build the pinned, embedded ZeroTier SDK with Xcode (no phone VPN app).

Usage: python3 scripts/build-zerotier.py [--cmake /path/to/cmake]
Generated sources and static XCFramework stay under ignored Build/ZeroTier.
"""
from pathlib import Path
import argparse
import io
import os
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'Build/ZeroTier'
SOURCES = [
    ('zerotier/libzt', 'a707ea6ae0910efdc1125d04758c411e2e9ea4f9', ''),
    ('zerotier/ZeroTierOne', 'c53c6bd9c320ea839c525972d8afba448a58606e', 'ext/ZeroTierOne'),
    ('joseph-henry/lwip', '32708c0a8b140efb545cc35101ee5fdeca6d6489', 'ext/lwip'),
    ('joseph-henry/lwip-contrib', '4fd612c9c72dfcd1db6618bd59c1a17d9f5b55f8', 'ext/lwip-contrib'),
]

def fetch(repo, ref, destination):
    request = urllib.request.Request(f'https://codeload.github.com/{repo}/tar.gz/{ref}', headers={'User-Agent': 'AstroGate-build'})
    with urllib.request.urlopen(request, timeout=90) as response:
        archive = response.read()
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as tar:
        for member in tar.getmembers():
            parts = Path(member.name).parts[1:]
            if not parts or not member.isfile():
                continue
            target = destination.joinpath(*parts)
            if not target.resolve().is_relative_to(destination.resolve()):
                raise RuntimeError('Unsafe SDK archive path')
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(tar.extractfile(member).read())

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cmake', default='cmake')
    args = parser.parse_args()
    framework = OUT / 'zt.xcframework'
    if (framework / 'Info.plist').exists():
        print('Using existing', framework)
        return
    source = OUT / 'source'
    for repo, ref, subdir in SOURCES:
        fetch(repo, ref, source / subdir)
    cmake = source / 'CMakeLists.txt'
    text = cmake.read_text().replace('set(CMAKE_OSX_SYSROOT "${SDKROOT}")', '')
    text = text.replace('target_compile_options(${XCODE_FRAMEWORK_NAME} PUBLIC -fembed-bitcode)', '')
    text = text.replace('target_link_libraries(${XCODE_FRAMEWORK_NAME} PUBLIC -fembed-bitcode)', '')
    cmake.write_text(text)
    frameworks = []
    for sdk in ['iphoneos', 'iphonesimulator']:
        build = OUT / sdk
        subprocess.run([args.cmake, '-S', str(source), '-B', str(build), '-G', 'Xcode', '-DBUILD_IOS_FRAMEWORK=TRUE', '-DCMAKE_OSX_ARCHITECTURES=arm64', '-DCMAKE_OSX_SYSROOT='+sdk, '-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0'], check=True)
        subprocess.run(['xcodebuild', '-quiet', '-project', str(build/'zt.xcodeproj'), '-target', 'zt', '-configuration', 'Release', '-sdk', sdk, 'ARCHS=arm64', 'IPHONEOS_DEPLOYMENT_TARGET=17.0', 'CODE_SIGNING_ALLOWED=NO', 'ENABLE_BITCODE=NO'], check=True)
        frameworks += ['-framework', str(build/'lib/Release/zt.framework')]
    subprocess.run(['xcodebuild', '-create-xcframework', *frameworks, '-output', str(framework)], check=True)

if __name__ == '__main__':
    main()
