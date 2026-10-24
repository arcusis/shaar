#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(uname -m) == arm64 ]] || { echo 'Pinned engine requires Apple silicon.' >&2; exit 1; }
pin=ThirdParty/ArdiaCore/pin.json
checksum=$(jq -er .sha256 "$pin")
tree=$(jq -er .engineTree "$pin")
url=$(jq -er .archiveURL "$pin")
key=${tree:0:12}
cache="$PWD/build/EngineCache"
archive="$cache/ArdiaCore-$key.tar.xz"
mkdir -p "$cache"
verify() { [[ $(shasum -a 256 "$1" | cut -d ' ' -f 1) == "$checksum" ]]; }
if [[ ! -f "$archive" ]] || ! verify "$archive"; then
  echo "Fetching pinned ArdiaCore $key..." >&2
  curl --fail --location --retry 3 "$url" --output "$archive.partial" >&2
  verify "$archive.partial" || { echo 'Engine checksum mismatch; refusing extraction.' >&2; exit 1; }
  mv "$archive.partial" "$archive"
fi
destination="$cache/$key"
if [[ ! -f "$destination/.verified-$checksum" ]]; then
  if tar -tf "$archive" | rg '(^/|(^|/)\.\.(/|$))' >&2; then
    echo 'Unsafe archive path; refusing extraction.' >&2
    exit 1
  fi
  mkdir -p "$destination"
  tar -xf "$archive" -C "$destination"
  touch "$destination/.verified-$checksum"
fi
framework="$destination/Chromium Framework.framework"
[[ -f "$framework/Versions/Current/Chromium Framework" ]] || { echo 'Engine framework missing.' >&2; exit 1; }
printf '%s\n' "$framework"
