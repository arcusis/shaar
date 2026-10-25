#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration=release
with_engine=false
seen_configuration=false
seen_engine=false
while (($#)); do
  case "$1" in
    --configuration)
      if $seen_configuration || (($# < 2)) || [[ "$2" == --* ]]; then
        echo 'Usage: bundle-app.sh [--configuration release|debug] [--with-engine]' >&2
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
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

swift build -c "$configuration"
binary_dir=$(swift build -c "$configuration" --show-bin-path)
if $with_engine; then
  app="build/Arcusis Browser.app"
else
  app="build/Arcusis Browser Shell.app"
fi
if [[ "$configuration" == debug ]]; then
  app="${app%.app} Debug.app"
fi
mkdir -p "$app/Contents/MacOS"
cp "$binary_dir/ArcusisBrowser" "$app/Contents/MacOS/ArcusisBrowser"
mkdir -p "$app/Contents/Resources/ArdiaCore"
cp ThirdParty/ArdiaCore/LICENSE ThirdParty/ArdiaCore/NOTICE ThirdParty/ArdiaCore/pin.json \
  "$app/Contents/Resources/ArdiaCore/"
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
  <key>CFBundleName</key><string>Arcusis Browser</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
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
if [[ "$configuration" == debug ]]; then
  printf 'Built %s (debug development bundle; local ad-hoc signature; not notarized or release-ready).\n' "$app"
else
  printf 'Built %s (local ad-hoc signature; not notarized).\n' "$app"
fi
