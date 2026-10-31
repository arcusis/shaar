#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration=release
with_engine=false
with_native_bitwarden_sdk=false
seen_configuration=false
seen_engine=false
seen_native_bitwarden_sdk=false
while (($#)); do
  case "$1" in
    --configuration)
      if $seen_configuration || (($# < 2)) || [[ "$2" == --* ]]; then
        echo 'Usage: bundle-app.sh [--configuration release|debug] [--with-engine] [--with-native-bitwarden-sdk]' >&2
        exit 2
      fi
      case "$2" in
        release|debug) configuration="$2" ;;
        *) echo "Unknown configuration: $2" >&2; exit 2 ;;
      esac
      seen_configuration=true
      shift 2
      ;;
    --with-engine)
      if $seen_engine; then
        echo 'Duplicate option: --with-engine' >&2
        exit 2
      fi
      seen_engine=true
      with_engine=true
      shift
      ;;
    --with-native-bitwarden-sdk)
      if $seen_native_bitwarden_sdk; then
        echo 'Duplicate option: --with-native-bitwarden-sdk' >&2
        exit 2
      fi
      seen_native_bitwarden_sdk=true
      with_native_bitwarden_sdk=true
      shift
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# Candidate packages have distinct payloads and are unsupported by this bundler.
# Reject even empty or disabled values so the inherited mode cannot be ambiguous.
if [[ ${ARCUSIS_NATIVE_BITWARDEN_ORGANIZATION_CANDIDATE+x} || ${ARCUSIS_NATIVE_BITWARDEN_REFRESH_CANDIDATE+x} || ${ARCUSIS_NATIVE_BITWARDEN_REFRESH_FIXTURE+x} ]]; then
  echo 'Unsupported native Bitwarden candidate environment; unset candidate flags before bundling.' >&2
  exit 1
fi

sdk_package="build/NativeBitwardenSDK/Package"
scratch_mode=default
if $with_native_bitwarden_sdk; then
  scratch_mode=native-bitwarden-sdk
  if [[ ! -d "$sdk_package" ]]; then
    echo 'Native Bitwarden SDK package missing; refusing SDK bundle.' >&2
    exit 1
  fi
  "${PYTHON:-.venv/bin/python}" - "$sdk_package" <<'PY'
import json
import runpy
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve(strict=True)
module = runpy.run_path("scripts/build-native-bitwarden-sdk.py")
manifest_path = root / "build-manifest.json"
manifest = json.loads(manifest_path.read_text())
module["validate_package"](root, manifest)
if manifest.get("accepted") is not True or manifest.get("architecture") != "arm64":
    raise SystemExit("Native Bitwarden SDK package is not accepted for this build.")
print("Validated pinned native Bitwarden SDK package inventory.")
PY
fi
scratch_path="build/swiftpm/$scratch_mode"
mkdir -p "$scratch_path"
if $with_native_bitwarden_sdk; then
  ARCUSIS_NATIVE_BITWARDEN_SDK=1 swift build --manifest-cache none --scratch-path "$scratch_path" -c "$configuration"
  binary_dir=$(ARCUSIS_NATIVE_BITWARDEN_SDK=1 swift build --manifest-cache none --scratch-path "$scratch_path" -c "$configuration" --show-bin-path)
else
  ARCUSIS_NATIVE_BITWARDEN_SDK=0 swift build --manifest-cache none --scratch-path "$scratch_path" -c "$configuration"
  binary_dir=$(ARCUSIS_NATIVE_BITWARDEN_SDK=0 swift build --manifest-cache none --scratch-path "$scratch_path" -c "$configuration" --show-bin-path)
fi
if $with_engine; then
  app="build/Shaar.app"
else
  app="build/Shaar Shell.app"
fi
if [[ "$configuration" == debug ]]; then
  app="${app%.app} Debug.app"
fi
# Start from an empty bundle so files from earlier builds, such as an old icon, never linger.
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$binary_dir/ArcusisBrowser" "$app/Contents/MacOS/ArcusisBrowser"
"${PYTHON:-python3}" scripts/stage-browser-resources.py \
  "$binary_dir" "$app/Contents/Resources"
sdk_frameworks="$app/Contents/Frameworks"
sdk_resources="$app/Contents/Resources/NativeBitwardenSDK"
if ! $with_native_bitwarden_sdk; then
  rm -rf "$sdk_frameworks/libbitwarden_uniffi.dylib" "$sdk_resources"
fi
mkdir -p "$app/Contents/Resources/ArdiaCore"
cp ThirdParty/ArdiaCore/LICENSE ThirdParty/ArdiaCore/NOTICE ThirdParty/ArdiaCore/pin.json \
  "$app/Contents/Resources/ArdiaCore/"
cp Resources/Branding/Shaar.icns "$app/Contents/Resources/Shaar.icns"
if $with_native_bitwarden_sdk; then
  source_dylib="$sdk_package/Frameworks/BitwardenSDK.xcframework/macos-arm64/libbitwarden_uniffi.dylib"
  if [[ ! -f "$source_dylib" ]]; then
    echo 'Validated SDK package has no arm64 dylib; refusing SDK bundle.' >&2
    exit 1
  fi
  mkdir -p "$sdk_frameworks" "$sdk_resources/ThirdPartyNotices"
  cp "$source_dylib" "$sdk_frameworks/libbitwarden_uniffi.dylib"
  install_name_tool -id '@rpath/libbitwarden_uniffi.dylib' \
    "$sdk_frameworks/libbitwarden_uniffi.dylib"
  # SwiftPM adds its package Frameworks directory as an absolute build rpath.
  # Remove it so runtime resolves only the app's relative Frameworks directory.
  install_name_tool -delete_rpath "$binary_dir/PackageFrameworks" \
    "$app/Contents/MacOS/ArcusisBrowser"
  for notice in DISCLAIMER.md LICENSE LICENSE_GPL.txt LICENSE_SDK.txt; do
    cp "$sdk_package/ThirdPartyNotices/$notice" "$sdk_resources/ThirdPartyNotices/"
  done
  codesign --force --timestamp=none --sign - "$sdk_frameworks/libbitwarden_uniffi.dylib"
fi
if $with_engine; then
  framework=$(bash scripts/fetch-engine.sh)
  mkdir -p "$app/Contents/Frameworks"
  # Keep version symlinks and upstream resources. Re-sign nested code inside out.
  ditto "$framework" "$app/Contents/Frameworks/Chromium Framework.framework"
  staged="$app/Contents/Frameworks/Chromium Framework.framework"
  for library in "$staged"/Versions/Current/Libraries/*.dylib; do
    codesign --force --timestamp=none --sign - "$library"
  done
  for helper in "$staged"/Versions/Current/Helpers/*; do
    if [[ -d "$helper" && "$helper" == *.app ]] || [[ -f "$helper" && -x "$helper" ]]; then
      codesign --force --timestamp=none --sign - "$helper"
    fi
  done
  codesign --force --timestamp=none --sign - "$staged"
fi
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>ArcusisBrowser</string>
  <key>CFBundleIdentifier</key><string>com.arcusis.browser</string>
  <key>CFBundleName</key><string>Shaar</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>Web URLs</string>
    <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
  </dict></array>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>Shaar.icns</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Arcusis. All rights reserved.</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>UTExportedTypeDeclarations</key><array><dict>
    <key>UTTypeIdentifier</key><string>com.arcusis.browser.sidebar-item</string>
    <key>UTTypeDescription</key><string>Arcusis Sidebar Item</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string></array>
  </dict></array>
  <key>NSCameraUsageDescription</key><string>Allow websites you approve to use your camera for video calls.</string>
  <key>NSMicrophoneUsageDescription</key><string>Allow websites you approve to use your microphone for calls.</string>
</dict></plist>
PLIST
codesign --force --timestamp=none --sign - "$app"
codesign --verify --deep --strict "$app"
if $with_native_bitwarden_sdk; then
  printf 'Built %s (local native SDK development bundle; ad-hoc signed; not notarized or release-ready).\n' "$app"
elif [[ "$configuration" == debug ]]; then
  printf 'Built %s (debug development bundle; local ad-hoc signature; not notarized or release-ready).\n' "$app"
else
  printf 'Built %s (local ad-hoc signature; not notarized).\n' "$app"
fi
