#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Validate the shared release constants before bash sources them.
"${PYTHON:-python3}" scripts/release_feed.py describe >/dev/null
source scripts/release-config.sh
source scripts/engine-signing.sh
# Development bundles are signed ad hoc for local use only.
adhoc_sign() { codesign --force --timestamp=none --sign - "$1"; }
configuration=release
with_engine=false
with_updates=false
seen_configuration=false
seen_engine=false
seen_updates=false
while (($#)); do
  case "$1" in
    --configuration)
      if $seen_configuration || (($# < 2)) || [[ "$2" == --* ]]; then
        echo 'Usage: bundle-app.sh [--configuration release|debug] [--with-engine] [--with-updates]' >&2
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
    --with-updates)
      if $seen_updates; then
        echo 'Duplicate option: --with-updates' >&2
        exit 2
      fi
      seen_updates=true
      with_updates=true
      shift
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
# The update feed belongs only in release engine bundles; release.sh is its one caller.
if $with_updates && { [[ "$configuration" != release ]] || ! $with_engine; }; then
  echo '--with-updates requires --configuration release and --with-engine.' >&2
  exit 2
fi

scratch_path="build/swiftpm/default"
mkdir -p "$scratch_path"
swift build --manifest-cache none --scratch-path "$scratch_path" -c "$configuration"
binary_dir=$(swift build --manifest-cache none --scratch-path "$scratch_path" -c "$configuration" --show-bin-path)
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
# SwiftPM can add its package Frameworks directory as an absolute build rpath.
# Remove it so runtime resolves only the app's relative Frameworks directory.
package_rpath="$binary_dir/PackageFrameworks"
load_commands=$(otool -l "$app/Contents/MacOS/ArcusisBrowser")
if [[ "$load_commands" == *"path $package_rpath "* ]]; then
  install_name_tool -delete_rpath "$package_rpath" "$app/Contents/MacOS/ArcusisBrowser"
fi
"${PYTHON:-python3}" scripts/stage-browser-resources.py \
  "$binary_dir" "$app/Contents/Resources"
cp Resources/Branding/Shaar.icns "$app/Contents/Resources/Shaar.icns"
cp -R Resources/ExtensionManager "$app/Contents/Resources/ExtensionManager"
mkdir -p "$app/Contents/Resources/ArdiaCore"
cp ThirdParty/ArdiaCore/LICENSE ThirdParty/ArdiaCore/NOTICE ThirdParty/ArdiaCore/pin.json \
  "$app/Contents/Resources/ArdiaCore/"
# The executable links Sparkle, so every bundle embeds it. Copy the pinned SwiftPM artifact
# unchanged: its own signatures and entitlements stay intact for release re-signing.
mkdir -p "$app/Contents/Frameworks"
ditto "$binary_dir/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
mkdir -p "$app/Contents/Resources/Sparkle"
cp "$scratch_path/artifacts/sparkle/Sparkle/LICENSE" "$app/Contents/Resources/Sparkle/LICENSE"
if $with_engine; then
  framework=$(bash scripts/fetch-engine.sh)
  # Keep version symlinks and upstream resources. Re-sign nested code inside out.
  ditto "$framework" "$app/Contents/Frameworks/Chromium Framework.framework"
  sign_engine_framework "$app/Contents/Frameworks/Chromium Framework.framework" adhoc_sign
fi
# Only release bundles carry the update feed; without it the app never starts Sparkle.
update_keys=''
if $with_updates; then
  update_keys="  <key>SUFeedURL</key><string>$SHAAR_FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SHAAR_SPARKLE_PUBLIC_ED_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUEnableInstallerLauncherService</key><true/>"
fi
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>ArcusisBrowser</string>
  <key>CFBundleIdentifier</key><string>$SHAAR_BUNDLE_IDENTIFIER</string>
  <key>CFBundleName</key><string>Shaar</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>Web URLs</string>
    <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
  </dict></array>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>Shaar.icns</string>
  <key>CFBundleShortVersionString</key><string>$SHAAR_BUNDLE_VERSION</string>
  <key>CFBundleVersion</key><string>$SHAAR_BUILD_VERSION</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Arcusis. All rights reserved.</string>
  <key>LSMinimumSystemVersion</key><string>$SHAAR_MINIMUM_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>UTExportedTypeDeclarations</key><array><dict>
    <key>UTTypeIdentifier</key><string>com.arcusis.browser.sidebar-item</string>
    <key>UTTypeDescription</key><string>Arcusis Sidebar Item</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string></array>
  </dict></array>
  <key>NSCameraUsageDescription</key><string>Allow websites you approve to use your camera for video calls.</string>
  <key>NSMicrophoneUsageDescription</key><string>Allow websites you approve to use your microphone for calls.</string>
  <key>NSLocationUsageDescription</key><string>Allow websites you approve to use your location, such as maps and delivery sites.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>Allow websites you approve to use your location, such as maps and delivery sites.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Allow websites you approve to connect to Bluetooth devices, such as security keys and phones used for passkey sign-in.</string>
$update_keys
</dict></plist>
PLIST
adhoc_sign "$app"
codesign --verify --deep --strict "$app"
if [[ "$configuration" == debug ]]; then
  printf 'Built %s (debug development bundle; local ad-hoc signature; not notarized or release-ready).\n' "$app"
else
  printf 'Built %s (local ad-hoc signature; not notarized).\n' "$app"
fi
