#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

branding="Resources/Branding"
source="$branding/Arcusis.png"
output="$branding/Arcusis.icns"
if [[ ! -f "$source" ]]; then
  echo "Missing source icon: $source" >&2
  exit 1
fi

temporary=$(mktemp -d "$branding/.Arcusis.XXXXXX")
iconset="$temporary/Arcusis.iconset"
mkdir "$iconset"
trap 'rm -rf "$temporary"' EXIT

for entry in "16 16" "16 32" "32 32" "32 64" "128 128" "128 256" "256 256" "256 512" "512 512" "512 1024"; do
  read -r size pixels <<<"$entry"
  suffix=""
  if ((pixels == size * 2)); then suffix="@2x"; fi
  sips -z "$pixels" "$pixels" "$source" --out "$iconset/icon_${size}x${size}${suffix}.png" >/dev/null
done

iconutil -c icns -o "$output" "$iconset"
