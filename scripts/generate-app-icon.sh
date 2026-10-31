#!/bin/bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

set -euo pipefail
cd "$(dirname "$0")/.."

# Branding/shaar-app-icon.svg is the master; the bundled ICNS is generated from it.
source="Branding/shaar-app-icon.svg"
output="Resources/Branding/Shaar.icns"
if [[ ! -f "$source" ]]; then
  echo "Missing source icon: $source" >&2
  exit 1
fi

temporary=$(mktemp -d "Resources/Branding/.Shaar.XXXXXX")
iconset="$temporary/Shaar.iconset"
rendered="$temporary/icon-1024.png"
mkdir "$iconset"
trap 'rm -rf "$temporary"' EXIT

swift - "$source" "$rendered" <<'SWIFT'
import AppKit

let arguments = CommandLine.arguments
guard let image = NSImage(contentsOf: URL(fileURLWithPath: arguments[1])),
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)
else { fatalError("Could not load \(arguments[1])") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
image.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[2]))
SWIFT

for entry in "16 16" "16 32" "32 32" "32 64" "128 128" "128 256" "256 256" "256 512" "512 512" "512 1024"; do
  read -r size pixels <<<"$entry"
  suffix=""
  if ((pixels == size * 2)); then suffix="@2x"; fi
  sips -z "$pixels" "$pixels" "$rendered" --out "$iconset/icon_${size}x${size}${suffix}.png" >/dev/null
done

iconutil -c icns -o "$output" "$iconset"
cp "$rendered" Branding/shaar-app-icon-1024.png
echo "Wrote $output and Branding/shaar-app-icon-1024.png"
