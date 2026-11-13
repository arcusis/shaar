#!/bin/bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 /path/to/Shaar.app /path/to/Shaar.dmg" >&2
  exit 2
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$1"
output="$2"
if [[ ! -d "$app/Contents" || "$(basename "$app")" != "Shaar.app" ]]; then
  echo "Expected a Shaar.app bundle" >&2
  exit 2
fi
if [[ -L "$output" ]]; then
  echo "Output must not be a symlink: $output" >&2
  exit 2
fi
if [[ -e "$output" ]]; then
  echo "Output already exists: $output" >&2
  exit 2
fi

work="$(mktemp -d)"
mounted=false
cleanup() {
  if $mounted; then hdiutil detach "$work/mount" -quiet || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/stage/.background" "$work/mount"
ditto "$app" "$work/stage/Shaar.app"
ln -s /Applications "$work/stage/Applications"
cp "$root/Resources/Installer/background.png" "$work/stage/.background/background.png"
cp "$root/Resources/Installer/.DS_Store" "$work/stage/.DS_Store"
cp "$root/Resources/Branding/Shaar.icns" "$work/stage/.VolumeIcon.icns"

hdiutil create -quiet -volname Shaar -srcfolder "$work/stage" -format UDRW "$work/layout.dmg"
hdiutil attach "$work/layout.dmg" -quiet -nobrowse -noautoopen -mountpoint "$work/mount"
mounted=true
xcrun SetFile -a C "$work/mount"
hdiutil detach "$work/mount" -quiet
mounted=false
hdiutil convert "$work/layout.dmg" -quiet -format UDZO -o "$output"
echo "$output"
