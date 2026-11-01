#!/bin/bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

set -euo pipefail
cd "$(dirname "$0")/.."
# Validate the shared release constants before bash sources them.
"${PYTHON:-python3}" scripts/release_feed.py describe >/dev/null
source scripts/release-config.sh
source scripts/engine-signing.sh
# Development bundles are signed ad hoc for local use only.
adhoc_sign() { codesign --force --timestamp=none --sign - "$1"; }
# Probes live only in the ShaarVerification harness; a shipped executable must not contain them.
assert_no_verification_code() {
  if LC_ALL=C grep -a -F -q -e ShaarVerification -e EngineProbe -e --engine-probe -e --probe-data-dir "$1"; then
    echo "Verification code found in $1." >&2
    exit 1
  fi
}
configuration=release
with_engine=false
with_updates=false
with_verification=false
seen_configuration=false
seen_engine=false
seen_updates=false
seen_verification=false
while (($#)); do
  case "$1" in
    --configuration)
      if $seen_configuration || (($# < 2)) || [[ "$2" == --* ]]; then
        echo 'Usage: bundle-app.sh [--configuration release|debug] [--with-engine] [--with-updates] [--verification]' >&2
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
    --verification)
      if $seen_verification; then
        echo 'Duplicate option: --verification' >&2
        exit 2
      fi
      seen_verification=true
      with_verification=true
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
# The verification harness drives the real engine and never ships, so it never carries a feed.
if $with_verification && { ! $with_engine || $with_updates; }; then
  echo '--verification requires --with-engine and excludes --with-updates.' >&2
  exit 2
fi

bundle_identifier=$SHAAR_BUNDLE_IDENTIFIER
if $with_verification; then
  executable=ShaarVerification
  bundle_identifier=$SHAAR_VERIFICATION_BUNDLE_IDENTIFIER
  scratch_path="build/swiftpm/verification"
  app="build/Shaar Verification.app"
elif $with_engine; then
  executable=ArcusisBrowser
  scratch_path="build/swiftpm/default"
  app="build/Shaar.app"
else
  executable=ArcusisBrowser
  scratch_path="build/swiftpm/default"
  app="build/Shaar Shell.app"
fi
swift_build() {
  swift build --manifest-cache none --scratch-path "$scratch_path" -c "$configuration" "$@"
}
mkdir -p "$scratch_path"
if $with_verification; then
  # ShaarVerification imports the app module with @testable. Its own scratch path keeps
  # testing-enabled objects out of the shipping build, which never passes -enable-testing.
  swift_build --product "$executable" -Xswiftc -enable-testing
else
  swift_build --product "$executable"
fi
binary_dir=$(swift_build --show-bin-path)
if [[ "$configuration" == debug ]]; then
  app="${app%.app} Debug.app"
fi
# Start from an empty bundle so files from earlier builds, such as an old icon, never linger.
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$binary_dir/$executable" "$app/Contents/MacOS/$executable"
if ! $with_verification; then
  assert_no_verification_code "$app/Contents/MacOS/$executable"
fi
# SwiftPM can add its package Frameworks directory as an absolute build rpath.
# Remove it so runtime resolves only the app's relative Frameworks directory.
package_rpath="$binary_dir/PackageFrameworks"
load_commands=$(otool -l "$app/Contents/MacOS/$executable")
if [[ "$load_commands" == *"path $package_rpath "* ]]; then
  install_name_tool -delete_rpath "$package_rpath" "$app/Contents/MacOS/$executable"
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
  <key>CFBundleExecutable</key><string>$executable</string>
  <key>CFBundleIdentifier</key><string>$bundle_identifier</string>
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
if $with_verification; then
  printf 'Built %s (verification harness; local ad-hoc signature; never distributed).\n' "$app"
elif [[ "$configuration" == debug ]]; then
  printf 'Built %s (debug development bundle; local ad-hoc signature; not notarized or release-ready).\n' "$app"
else
  printf 'Built %s (local ad-hoc signature; not notarized).\n' "$app"
fi
