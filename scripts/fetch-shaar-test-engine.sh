#!/bin/bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Fetch only the SHA-256 pinned test framework; never changes the shipping engine pin.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(uname -m) == arm64 ]] || { echo 'Shaar test engine requires Apple silicon.' >&2; exit 1; }
build_root="$PWD/build"
cache="$build_root/ShaarEngineTestCache"
if [[ -L "$build_root" || -L "$cache" ]]; then
  echo 'Shaar test engine cache root must not be a symlink.' >&2; exit 1
fi
if [[ ( -e "$build_root" && ! -d "$build_root" ) || ( -e "$cache" && ! -d "$cache" ) ]]; then
  echo 'Shaar test engine cache root must be a directory.' >&2; exit 1
fi
pin=ThirdParty/ChromiumEngine/ci-test-pin.json
jq -e '.schemaVersion == 1 and .sourceKind == "shaar" and
  (.releaseTag | test("^engine-155\\.0\\.8059\\.84-shaar\\.[1-9][0-9]*$")) and
  (.asset | test("^ShaarEngine-155\\.0\\.8059\\.84-shaar\\.[1-9][0-9]*\\.tar\\.xz$")) and
  (.sha256 | test("^[0-9a-f]{64}$"))' "$pin" >/dev/null
tag=$(jq -er .releaseTag "$pin")
asset=$(jq -er .asset "$pin")
checksum=$(jq -er .sha256 "$pin")
[[ $asset == "ShaarEngine-${tag#engine-}.tar.xz" ]] || {
  echo 'Shaar test asset and tag do not match.' >&2; exit 1;
}
archive="$cache/$asset"
mkdir -p "$cache"
if [[ -L "$archive" ]]; then
  echo 'Shaar test archive cache path must not be a symlink.' >&2
  exit 1
fi
verify() { [[ $(shasum -a 256 "$1" | cut -d ' ' -f 1) == "$checksum" ]]; }
if [[ ! -f "$archive" ]] || ! verify "$archive"; then
  gh release download "$tag" --repo "${GITHUB_REPOSITORY:-arcusis/shaar}" \
    --pattern "$asset" --dir "$cache" --clobber >&2
  verify "$archive" || { echo 'Shaar test archive SHA-256 mismatch.' >&2; exit 1; }
fi
destination="$cache/${checksum:0:16}"
if [[ ! -f "$destination/.verified-$checksum" ]]; then
  archive_paths=$(tar -tf "$archive") || { echo 'Invalid Shaar test archive.' >&2; exit 1; }
  if /usr/bin/grep -E '(^/|(^|/)\.\.(/|$))' <<< "$archive_paths" >&2; then
    echo 'Unsafe Shaar test archive path.' >&2; exit 1
  else
    validation_status=$?
    [[ $validation_status == 1 ]] || {
      echo 'Shaar test archive path validation failed.' >&2; exit 1;
    }
  fi
  staging=$(mktemp -d "$cache/stage.XXXXXXXX")
  trap 'rm -rf "$staging"' EXIT
  tar -xf "$archive" -C "$staging"
  framework="$staging/Chromium Framework.framework"
  [[ -f "$framework/Versions/Current/Chromium Framework" ]] || {
    echo 'Shaar test framework missing.' >&2; exit 1;
  }
  python3 scripts/engine_payload.py --archive "$archive" --framework "$framework" \
    --pin "$pin" >/dev/null
  rm -rf "$destination"
  mv "$staging" "$destination"
  touch "$destination/.verified-$checksum"
fi
framework="$destination/Chromium Framework.framework"
python3 scripts/engine_payload.py --archive "$archive" --framework "$framework" \
  --pin "$pin" >/dev/null
printf '%s\n' "$framework"
