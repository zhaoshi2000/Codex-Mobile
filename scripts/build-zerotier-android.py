#!/usr/bin/env python3
"""Build the same pinned libzt as iOS for Android, keeping outputs out of Git."""
import argparse
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'Build/AndroidZeroTier'

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--sdk', default=os.environ.get('ANDROID_HOME'))
    parser.add_argument('--abis', default='arm64-v8a,armeabi-v7a,x86_64,x86')
    args = parser.parse_args()
    sdk = Path(args.sdk or '')
    ndk = sdk / 'ndk/28.2.13676358'
    suffix = '.exe' if os.name == 'nt' else ''
    cmake = sdk / ('cmake/3.22.1/bin/cmake' + suffix)
    ninja = sdk / ('cmake/3.22.1/bin/ninja' + suffix)
    if not cmake.exists() or not ndk.exists():
        raise SystemExit('Install SDK packages: ndk;28.2.13676358 and cmake;3.22.1')
    spec = importlib.util.spec_from_file_location('pinned', ROOT/'scripts/build-zerotier.py')
    pinned = importlib.util.module_from_spec(spec); spec.loader.exec_module(pinned)
    source = OUT/'source'
    if not (source/'.ready').exists():
        for repo, ref, folder in pinned.SOURCES:
            pinned.fetch(repo, ref, source/folder)
        (source/'.ready').write_text('pinned libzt\n')
    # Upstream JNI must not hold a GC-critical array while a socket blocks.
    # Also fix its offset-write array indexing before compiling on modern NDK.
    binding=source/'src/bindings/java/JavaSockets.cxx'
    text=binding.read_text()
    text=text.replace('void* data = env->GetPrimitiveArrayCritical(buf, NULL);',
                      'jbyte* data = env->GetByteArrayElements(buf, NULL);')
    text=text.replace('void* data = env->GetPrimitiveArrayCritical(&(buf[offset]), NULL);   // PENDING: check?',
                      'jbyte* data = env->GetByteArrayElements(buf, NULL);')
    text=text.replace('env->ReleasePrimitiveArrayCritical(buf, data, 0);',
                      'env->ReleaseByteArrayElements(buf, data, 0);')
    # stop/free are invoked by a JVM-owned Java thread, which must never be
    # detached while its JNI frame is active (ART aborts the whole process).
    text=text.replace('    java_detach_from_thread();', '')
    start=text.index('Java_com_zerotier_sockets_ZeroTierNative_zts_1bsd_1write_1offset(')
    end=text.index('\n}',start)
    text=text[:start]+text[start:end].replace('zts_bsd_write(fd, data, len)', 'zts_bsd_write(fd, data + offset, len)')+text[end:]
    binding.write_text(text)
    for abi in args.abis.split(','):
        build = OUT/abi
        subprocess.run([str(cmake), '-S', str(source), '-B', str(build), '-G', 'Ninja',
            '-DCMAKE_MAKE_PROGRAM='+str(ninja), '-DCMAKE_TOOLCHAIN_FILE='+str(ndk/'build/cmake/android.toolchain.cmake'),
            '-DANDROID_ABI='+abi, '-DANDROID_PLATFORM=android-29', '-DANDROID_STL=c++_static',
            '-DCMAKE_BUILD_TYPE=Release', '-DZTS_ENABLE_JAVA=ON', '-DZTS_DISABLE_CENTRAL_API=ON',
            '-DCMAKE_SHARED_LINKER_FLAGS=-Wl,-z,max-page-size=16384'], check=True)
        subprocess.run([str(cmake),'--build',str(build),'--target','zt-shared','-j','6'],check=True)
        libs=list(build.rglob('libzt.so'))
        if len(libs)!=1: raise RuntimeError('Expected one libzt.so: '+str(libs))
        dest=OUT/'jniLibs'/abi;dest.mkdir(parents=True,exist_ok=True)
        shutil.copy2(libs[0],dest/'libzt.so')
        host='windows-x86_64' if os.name=='nt' else 'darwin-x86_64' if sys.platform=='darwin' else 'linux-x86_64'
        subprocess.run([str(ndk/'toolchains/llvm/prebuilt'/host/'bin'/('llvm-strip'+suffix)),
                        '--strip-unneeded',str(dest/'libzt.so')],check=True)

if __name__=='__main__': main()
