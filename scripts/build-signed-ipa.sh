#!/usr/bin/env bash
set -euo pipefail

: "${RUNNER_TEMP:?This script runs on a macOS GitHub Actions runner}"
: "${IOS_P12_BASE64:?Missing P12 secret}"
: "${IOS_P12_PASSWORD:?Missing P12 password secret}"
: "${IOS_PROFILE_BASE64:?Missing provisioning profile secret}"

bundle_id='com.example.AstroGate'
team_id='YOUR_TEAM_ID'
expected_profile_uuid='YOUR_PROFILE_UUID'

signing_dir="$(mktemp -d "${RUNNER_TEMP}/ifileplus-signing.XXXXXX")"
keychain="${signing_dir}/build.keychain-db"
installed_profile=''
cleanup() {
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  if [[ -n "$installed_profile" ]]; then rm -f "$installed_profile"; fi
  rm -rf "$signing_dir"
}
trap cleanup EXIT

printf '%s' "$IOS_P12_BASE64" | base64 -D > "${signing_dir}/certificate.p12"
printf '%s' "$IOS_PROFILE_BASE64" | base64 -D > "${signing_dir}/profile.mobileprovision"
security cms -D -i "${signing_dir}/profile.mobileprovision" -o "${signing_dir}/profile.plist"

profile_uuid="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "${signing_dir}/profile.plist")"
profile_name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "${signing_dir}/profile.plist")"
profile_app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "${signing_dir}/profile.plist")"
profile_team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "${signing_dir}/profile.plist")"
cert_sha1="$(python3 - "${signing_dir}/profile.plist" <<'PY'
import hashlib
import plistlib
import sys

with open(sys.argv[1], 'rb') as file:
    profile = plistlib.load(file)
print(hashlib.sha1(profile['DeveloperCertificates'][0]).hexdigest().upper())
PY
)"
[[ "$profile_uuid" == "$expected_profile_uuid" ]] || { echo 'Unexpected provisioning profile UUID' >&2; exit 1; }
[[ "$profile_app_id" == "${team_id}.${bundle_id}" ]] || { echo 'Provisioning profile does not match app ID' >&2; exit 1; }
[[ "$profile_team" == "$team_id" ]] || { echo 'Provisioning profile does not match team' >&2; exit 1; }

keychain_password="$(openssl rand -base64 32)"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "${signing_dir}/certificate.p12" -k "$keychain" -P "$IOS_P12_PASSWORD" -A -t cert -f pkcs12
security set-key-partition-list -S apple-tool:,apple: -k "$keychain_password" "$keychain"
security list-keychains -d user -s "$keychain"
security default-keychain -s "$keychain"
identities="$(security find-identity -v -p codesigning "$keychain")"
grep -F "$cert_sha1" <<< "$identities" >/dev/null || {
  echo 'Imported certificate does not match the provisioning profile' >&2
  exit 1
}

profile_dir="${HOME}/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$profile_dir"
installed_profile="${profile_dir}/${profile_uuid}.mobileprovision"
cp "${signing_dir}/profile.mobileprovision" "$installed_profile"

xcodebuild -version
xcodebuild -quiet -resolvePackageDependencies -project iFilePlus.xcodeproj -scheme iFilePlus
mkdir -p build
xcodebuild archive \
  -quiet \
  -project iFilePlus.xcodeproj \
  -scheme iFilePlus \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -archivePath build/iFilePlus.xcarchive

cat > "${signing_dir}/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>release-testing</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>${cert_sha1}</string>
  <key>teamID</key><string>${team_id}</string>
  <key>provisioningProfiles</key><dict>
    <key>${bundle_id}</key><string>${profile_name}</string>
  </dict>
</dict></plist>
EOF

xcodebuild -exportArchive \
  -quiet \
  -archivePath build/iFilePlus.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist "${signing_dir}/ExportOptions.plist"

ipa_count="$(find build/export -maxdepth 1 -name '*.ipa' -type f | wc -l | tr -d ' ')"
[[ "$ipa_count" == '1' ]] || { echo "Expected one IPA, found ${ipa_count}" >&2; exit 1; }
