#!/bin/bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(uname -m) == arm64 ]] || { echo 'Pinned engine requires Apple silicon.' >&2; exit 1; }
build_root="$PWD/build"
cache="$build_root/EngineCache"
if [[ -L "$build_root" || -L "$cache" ]]; then
  echo 'Engine cache root must not be a symlink.' >&2; exit 1
fi
if [[ ( -e "$build_root" && ! -d "$build_root" ) || ( -e "$cache" && ! -d "$cache" ) ]]; then
  echo 'Engine cache root must be a directory.' >&2; exit 1
fi
pin=ThirdParty/ChromiumEngine/pin.json
jq -e '.schemaVersion == 1 and .sourceKind == "shaar" and
  (.releaseTag | test("^engine-157\\.0\\.8103\\.51-shaar\\.[1-9][0-9]*$")) and
  (.asset | test("^ShaarEngine-157\\.0\\.8103\\.51-shaar\\.[1-9][0-9]*\\.tar\\.xz$")) and
  (.sha256 | test("^[0-9a-f]{64}$"))' "$pin" >/dev/null
tag=$(jq -er .releaseTag "$pin")
asset=$(jq -er .asset "$pin")
checksum=$(jq -er .sha256 "$pin")
[[ $asset == "ShaarEngine-${tag#engine-}.tar.xz" ]] || {
  echo 'Shaar engine asset and tag do not match.' >&2; exit 1;
}
archive="$cache/$asset"
mkdir -p "$cache"
if [[ -L "$archive" || -L "$archive.partial" ]]; then
  echo 'Engine archive cache paths must not be symlinks.' >&2
  exit 1
fi
verify() { [[ $(shasum -a 256 "$1" | cut -d ' ' -f 1) == "$checksum" ]]; }
if [[ ! -f "$archive" ]] || ! verify "$archive"; then
  echo "Fetching pinned Shaar engine $tag..." >&2
  curl --fail --location --connect-timeout 30 --max-time 900 --retry 3 --retry-max-time 180 \
    "https://github.com/arcusis/shaar/releases/download/$tag/$asset" \
    --output "$archive.partial" >&2
  verify "$archive.partial" || { echo 'Engine checksum mismatch; refusing extraction.' >&2; exit 1; }
  mv "$archive.partial" "$archive"
fi
destination="$cache/${checksum:0:16}"
if [[ -L "$destination" || ( -e "$destination" && ! -d "$destination" ) ]]; then
  echo 'Engine cache destination must be a regular directory.' >&2
  exit 1
fi
if [[ ! -f "$destination/.verified-$checksum" ]]; then
  archive_paths=$(tar -tf "$archive") || {
    echo 'Cannot inspect engine archive; refusing extraction.' >&2
    exit 1
  }
  if /usr/bin/grep -E '(^/|(^|/)\.\.(/|$))' <<< "$archive_paths" >&2; then
    echo 'Unsafe archive path; refusing extraction.' >&2
    exit 1
  else
    validation_status=$?
    [[ $validation_status == 1 ]] || {
      echo 'Archive path validation failed; refusing extraction.' >&2
      exit 1
    }
  fi
  staging=$(mktemp -d "$cache/stage.XXXXXXXX")
  trap 'rm -rf "$staging"' EXIT
  tar -xf "$archive" -C "$staging"
  framework="$staging/Chromium Framework.framework"
  [[ -f "$framework/Versions/Current/Chromium Framework" ]] || {
    echo 'Engine framework missing.' >&2; exit 1
  }
  python3 scripts/engine_payload.py --archive "$archive" --framework "$framework" --pin "$pin" >/dev/null || {
    echo 'Engine payload verification failed; refusing bundle.' >&2
    exit 1
  }
  rm -rf "$destination"
  mv "$staging" "$destination"
  touch "$destination/.verified-$checksum"
fi
framework="$destination/Chromium Framework.framework"
[[ -f "$framework/Versions/Current/Chromium Framework" ]] || { echo 'Engine framework missing.' >&2; exit 1; }
python3 scripts/engine_payload.py --archive "$archive" --framework "$framework" --pin "$pin" >/dev/null || {
  echo 'Engine payload verification failed; refusing bundle.' >&2
  exit 1
}
printf '%s\n' "$framework"
