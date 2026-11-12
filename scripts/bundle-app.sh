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
  "${PYTHON:-python3}" scripts/check-shipping-harness.py --binary "$1"
}
configuration=release
with_engine=false
with_updates=false
with_verification=false
preview_shaar_engine=false
seen_configuration=false
seen_engine=false
seen_updates=false
seen_verification=false
seen_preview_shaar_engine=false
seen_mock_keychain=false
mock_keychain=false
while (($#)); do
  case "$1" in
    --configuration)
      if $seen_configuration || (($# < 2)) || [[ "$2" == --* ]]; then
        echo 'Usage: bundle-app.sh [--configuration release|debug] [--with-engine] [--with-updates] [--verification] [--preview-shaar-engine] [--mock-keychain]' >&2
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
    --preview-shaar-engine)
      if $seen_preview_shaar_engine; then
        echo 'Duplicate option: --preview-shaar-engine' >&2
        exit 2
      fi
      seen_preview_shaar_engine=true
      preview_shaar_engine=true
      shift
      ;;
    --mock-keychain)
      if $seen_mock_keychain; then
        echo 'Duplicate option: --mock-keychain' >&2
        exit 2
      fi
      seen_mock_keychain=true
      mock_keychain=true
      shift
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
# Empty, 0, and false leave the flag's choice alone. 1 and true request the mock.
case ${SHAAR_MOCK_KEYCHAIN:-} in
  ''|0|false|FALSE|no|NO) ;;
  1|true|TRUE|yes|YES) mock_keychain=true ;;
  *)
    echo 'SHAAR_MOCK_KEYCHAIN must be 1, true, 0, false, or unset.' >&2
    exit 2
    ;;
esac
# The update feed belongs only in release engine bundles; release.sh is its one caller.
if $with_updates && { [[ "$configuration" != release ]] || ! $with_engine; }; then
  echo '--with-updates requires --configuration release and --with-engine.' >&2
  exit 2
fi
# A Developer ID release must keep the login keychain. Refuse the mock before the build.
if $with_updates && $mock_keychain; then
  echo 'error: release bundles refuse ShaarUseMockKeychain. Unset SHAAR_MOCK_KEYCHAIN and omit --mock-keychain.' >&2
  exit 2
fi
# The verification harness drives the real engine and never ships, so it never carries a feed.
if $with_verification && { ! $with_engine || $with_updates; }; then
  echo '--verification requires --with-engine and excludes --with-updates.' >&2
  exit 2
fi
if [[ ${SHAAR_TEST_SHAAR_ENGINE:-0} == 1 ]] && ! $with_verification; then
  echo 'The Shaar test engine is allowed only in a verification bundle.' >&2
  exit 2
fi
if $preview_shaar_engine && { ! $with_engine || $with_updates || $with_verification; }; then
  echo '--preview-shaar-engine requires --with-engine and excludes --with-updates and --verification.' >&2
  exit 2
fi
engine_pin=ThirdParty/ChromiumEngine/pin.json

bundle_identifier=$SHAAR_BUNDLE_IDENTIFIER
bundle_name=Shaar
data_folder_name='Arcusis Browser'
cache_folder_name=Shaar
if $with_verification; then
  executable=ShaarVerification
  bundle_identifier=$SHAAR_VERIFICATION_BUNDLE_IDENTIFIER
  scratch_path="build/swiftpm/verification"
  app="build/Shaar Verification.app"
elif $with_engine; then
  executable=ArcusisBrowser
  scratch_path="build/swiftpm/default"
  if $preview_shaar_engine; then
    bundle_identifier=com.arcusis.browser.engine-preview
    bundle_name='Shaar Engine Preview'
    data_folder_name='Shaar Engine Preview'
    cache_folder_name='Shaar Engine Preview'
    app="build/Shaar Engine Preview.app"
  else
    app="build/Shaar.app"
  fi
else
  executable=ArcusisBrowser
  scratch_path="build/swiftpm/default"
  app="build/Shaar Shell.app"
fi
swift_build() {
  if [[ -n ${SHAAR_BUNDLE_SWIFT_JOBS:-} ]]; then
    [[ $SHAAR_BUNDLE_SWIFT_JOBS =~ ^[1-9][0-9]*$ ]] || {
      echo 'SHAAR_BUNDLE_SWIFT_JOBS must be a positive integer.' >&2
      return 2
    }
    swift build --jobs "$SHAAR_BUNDLE_SWIFT_JOBS" --manifest-cache none \
      --scratch-path "$scratch_path" -c "$configuration" "$@"
    return
  fi
  swift build --manifest-cache none --scratch-path "$scratch_path" -c "$configuration" "$@"
}
mkdir -p "$scratch_path"
if $with_verification; then
  # ShaarVerification imports the app module with @testable. Its own scratch path keeps
  # testing-enabled objects out of the shipping build, which never passes -enable-testing.
  swift_build --product "$executable" -Xswiftc -enable-testing -Xcc -DSHAAR_VERIFICATION=1
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
# Stage every shipping SwiftPM resource bundle, including the Audits scripts.
# A produced ArcusisBrowser_*.bundle that is not copied into Contents/Resources fails the build.
"${PYTHON:-python3}" scripts/stage-browser-resources.py \
  "$binary_dir" "$app/Contents/Resources"
cp Resources/Branding/Shaar.icns "$app/Contents/Resources/Shaar.icns"
cp -R Resources/ExtensionManager "$app/Contents/Resources/ExtensionManager"
"${PYTHON:-python3}" scripts/fetch-framework-devtools.py \
  --output "$app/Contents/Resources/FrameworkDevTools"
mkdir -p "$app/Contents/Resources/Privacy"
cp Resources/Privacy/tracker-domains.json "$app/Contents/Resources/Privacy/"
mkdir -p "$app/Contents/Resources/ChromiumEngine"
cp "$engine_pin" "$app/Contents/Resources/ChromiumEngine/pin.json"
cp LICENSE NOTICE THIRD_PARTY_NOTICES.md \
  "$app/Contents/Resources/ChromiumEngine/"
# The executable links Sparkle, so every bundle embeds it. Copy the pinned SwiftPM artifact
# unchanged: its own signatures and entitlements stay intact for release re-signing.
mkdir -p "$app/Contents/Frameworks"
ditto "$binary_dir/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
mkdir -p "$app/Contents/Resources/Sparkle"
cp "$scratch_path/artifacts/sparkle/Sparkle/LICENSE" "$app/Contents/Resources/Sparkle/LICENSE"
if $with_engine; then
  if $with_verification && [[ ${SHAAR_TEST_SHAAR_ENGINE:-0} == 1 ]]; then
    framework=$(bash scripts/fetch-shaar-test-engine.sh)
  else
    framework=$(bash scripts/fetch-engine.sh)
  fi
  # Keep version symlinks and upstream resources. Re-sign nested code inside out.
  ditto "$framework" "$app/Contents/Frameworks/Chromium Framework.framework"
  python3 scripts/rebrand-engine-framework.py \
    "$app/Contents/Frameworks/Chromium Framework.framework"
  python3 - "$app/Contents/Frameworks/Chromium Framework.framework" "$bundle_name" \
    Resources/Branding/Shaar.icns <<'PY'
import plistlib
import shutil
import sys
from pathlib import Path

framework = Path(sys.argv[1])
product_name = sys.argv[2]
app_icon = Path(sys.argv[3])
helpers = sorted((framework / "Versions/Current/Helpers").glob("*Alerts*.app"))
if len(helpers) != 2:
    raise SystemExit("Expected both Chromium Alerts helpers in the bundled framework.")
for helper in helpers:
    contents = helper / "Contents"
    info_path = contents / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    if info.get("CFBundleIdentifier") != "com.arcusis.shaar.framework.AlertNotificationService":
        raise SystemExit(f"Unexpected Alerts helper identifier: {helper}")
    info["CFBundleName"] = product_name
    info["CFBundleDisplayName"] = product_name
    info["CFBundleIconFile"] = "app.icns"
    info.pop("CFBundleIconName", None)
    info_path.write_bytes(plistlib.dumps(info))
    resources = contents / "Resources"
    resources.mkdir(exist_ok=True)
    icon_path = resources / "app.icns"
    icon_path.unlink(missing_ok=True)
    shutil.copyfile(app_icon, icon_path)
    (resources / "Assets.car").unlink(missing_ok=True)
PY
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
# The engine preview always stays off the regular browser's Safe Storage item.
# Other ad-hoc bundles opt in with SHAAR_MOCK_KEYCHAIN or --mock-keychain.
mock_keychain_key=''
if $preview_shaar_engine || $mock_keychain; then
  mock_keychain_key='  <key>ShaarUseMockKeychain</key><true/>'
fi
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>he</string></array>
  <key>CFBundleExecutable</key><string>$executable</string>
  <key>CFBundleIdentifier</key><string>$bundle_identifier</string>
  <key>CFBundleName</key><string>$bundle_name</string>
  <key>CFBundleDisplayName</key><string>$bundle_name</string>
  <key>NSUserActivityTypes</key><array><string>NSUserActivityTypeBrowsingWeb</string></array>
  <key>ShaarDataFolderName</key><string>$data_folder_name</string>
  <key>ShaarCacheFolderName</key><string>$cache_folder_name</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>Web URLs</string>
    <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
  </dict></array>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Web Page</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array>
      <string>public.html</string><string>public.xhtml</string>
      <string>com.apple.web-internet-location</string>
    </array>
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
$mock_keychain_key
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
