#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$ROOT/iFilePlus.xcodeproj"
SCHEME="iFilePlus"
BUNDLE_ID="com.example.AstroGate"
TEAM_ID="YOUR_TEAM_ID"
PROFILE_NAME="YOUR_PROFILE_NAME"
PROFILE_UUID_EXPECTED="YOUR_PROFILE_UUID"
SIGNING_DIR="$ROOT/Signing"
P12="$SIGNING_DIR/signing.p12"
PROFILE="$SIGNING_DIR/signing.mobileprovision"
PASSWORD_FILE="$SIGNING_DIR/password.txt"
BUILD_DIR="$ROOT/Build"

fail() { echo "错误：$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "此脚本必须在 macOS 上运行，当前系统不是 macOS。"
command -v xcodebuild >/dev/null 2>&1 || fail "未找到 xcodebuild。请安装 Xcode，并至少启动一次完成初始化。"
command -v security >/dev/null 2>&1 || fail "未找到 macOS security 命令。"
command -v python3 >/dev/null 2>&1 || fail "未找到 python3。"
python3 "$ROOT/scripts/build-zerotier.py"
[[ -d "$PROJECT" ]] || fail "找不到 Xcode 工程：$PROJECT"
[[ -f "$P12" ]] || fail "缺少签名证书：$P12"
[[ -f "$PROFILE" ]] || fail "缺少描述文件：$PROFILE"

P12_PASSWORD=""
if [[ -f "$PASSWORD_FILE" ]]; then
  P12_PASSWORD="$(python3 - "$PASSWORD_FILE" <<'PY'
from pathlib import Path
import sys

value = Path(sys.argv[1]).read_text(encoding='utf-8-sig').strip()[2:].strip('：:= \t')
print(value, end='')
PY
)"
fi
if [[ -z "$P12_PASSWORD" ]]; then
  read -r -s -p "请输入 P12 证书密码：" P12_PASSWORD
  echo
fi
[[ -n "$P12_PASSWORD" ]] || fail "P12 密码为空。"

OPENSSL3="$(command -v openssl || true)"
if [[ -z "$OPENSSL3" ]] || ! "$OPENSSL3" version | grep -Eq '^OpenSSL 3\.'; then
  if command -v brew >/dev/null 2>&1; then
    OPENSSL3="$(brew --prefix openssl@3 2>/dev/null || true)/bin/openssl"
  fi
fi
[[ -x "$OPENSSL3" ]] && "$OPENSSL3" version | grep -Eq '^OpenSSL 3\.' || fail "需要 OpenSSL 3 才能转换此 P12；请安装 openssl@3。"

umask 077
mkdir -p "$BUILD_DIR"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ifileplus-sign.XXXXXX")"
KEYCHAIN="$WORK_DIR/ifileplus-build.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 24)"
OLD_KEYCHAINS=()
while IFS= read -r line; do
  line="${line#\"}"
  line="${line%\"}"
  [[ -n "$line" ]] && OLD_KEYCHAINS+=("$line")
done < <(security list-keychains -d user)

cleanup() {
  if [[ ${#OLD_KEYCHAINS[@]} -gt 0 ]]; then
    security list-keychains -d user -s "${OLD_KEYCHAINS[@]}" >/dev/null 2>&1 || true
  fi
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

security cms -D -i "$PROFILE" > "$WORK_DIR/profile.plist"
PROFILE_UUID="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$WORK_DIR/profile.plist")"
PROFILE_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$WORK_DIR/profile.plist")"
PROFILE_TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$WORK_DIR/profile.plist")"
PROFILE_DISPLAY_NAME="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$WORK_DIR/profile.plist")"
[[ "$PROFILE_APP_ID" == "$TEAM_ID.$BUNDLE_ID" ]] || fail "描述文件 App ID 不匹配：$PROFILE_APP_ID"
[[ "$PROFILE_TEAM_ID" == "$TEAM_ID" ]] || fail "描述文件 Team ID 不匹配：$PROFILE_TEAM_ID"
[[ "$PROFILE_DISPLAY_NAME" == "$PROFILE_NAME" ]] || fail "描述文件名称不匹配：$PROFILE_DISPLAY_NAME"
[[ "$PROFILE_UUID" == "$PROFILE_UUID_EXPECTED" ]] || fail "描述文件 UUID 不匹配：$PROFILE_UUID"
CERT_SHA1="$(python3 - "$WORK_DIR/profile.plist" <<'PY'
from pathlib import Path
import hashlib
import plistlib
import sys

profile = plistlib.loads(Path(sys.argv[1]).read_bytes())
print(hashlib.sha1(profile['DeveloperCertificates'][0]).hexdigest().upper())
PY
)"

PROFILE_INSTALL_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$PROFILE_INSTALL_DIR"
cp "$PROFILE" "$PROFILE_INSTALL_DIR/$PROFILE_UUID.mobileprovision"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
"$OPENSSL3" pkcs12 -in "$P12" -passin fd:3 -nodes \
  -out "$WORK_DIR/identity.pem" 3<<< "$P12_PASSWORD" >/dev/null
COMPAT_PASSWORD="$("$OPENSSL3" rand -hex 24)"
"$OPENSSL3" pkcs12 -export -in "$WORK_DIR/identity.pem" \
  -out "$WORK_DIR/compatible.p12" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -passout fd:3 3<<< "$COMPAT_PASSWORD" >/dev/null
unset P12_PASSWORD
security import "$WORK_DIR/compatible.p12" -k "$KEYCHAIN" -P "$COMPAT_PASSWORD" -A -t cert -f pkcs12 >/dev/null
unset COMPAT_PASSWORD
security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" "${OLD_KEYCHAINS[@]}"

IDENTITIES="$(security find-identity -v -p codesigning "$KEYCHAIN")"
if ! grep -F "$CERT_SHA1" <<< "$IDENTITIES" >/dev/null; then
  fail "P12 中的签名身份与描述文件不匹配"
fi

echo "==> 签名身份与描述文件已安装。"
echo "==> Bundle ID: $BUNDLE_ID"
echo "==> Profile UUID: $PROFILE_UUID"
echo "==> 解析 Swift Package 依赖..."
xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme "$SCHEME"

echo "==> 开始 Archive..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$BUILD_DIR/iFilePlus.xcarchive" \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  archive

echo "==> 导出 Ad Hoc IPA..."
rm -rf "$BUILD_DIR/export"
cp "$ROOT/ExportOptions.plist" "$WORK_DIR/ExportOptions.plist"
/usr/libexec/PlistBuddy -c "Set :signingCertificate $CERT_SHA1" "$WORK_DIR/ExportOptions.plist"
xcodebuild -exportArchive \
  -archivePath "$BUILD_DIR/iFilePlus.xcarchive" \
  -exportOptionsPlist "$WORK_DIR/ExportOptions.plist" \
  -exportPath "$BUILD_DIR/export"

IPA_PATH="$(find "$BUILD_DIR/export" -maxdepth 1 -name '*.ipa' -print -quit)"
[[ -n "$IPA_PATH" && -f "$IPA_PATH" ]] || fail "导出命令结束，但没有找到 IPA 文件。"
echo
echo "打包完成：$IPA_PATH"
echo "此 IPA 为 Ad Hoc 包，只能安装到该描述文件登记的设备。"
