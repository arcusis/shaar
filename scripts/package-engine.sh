#!/bin/bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Packs the framework of a successful scripts/build-engine-source.py run into an engine archive
# that pin.json can name. Every helper gets an ad hoc signature with the entitlements upstream's
# release grants it (allow-jit for the GPU and renderer helpers only), because release.sh copies
# helper entitlements from the pinned archive. The dSYM stays next to the archive and is never
# published. Usage: package-engine.sh <build label>, for example shaar.1.

set -euo pipefail
cd "$(dirname "$0")/.."
label=${1:?usage: package-engine.sh <build label, e.g. shaar.1>}
[[ $label =~ ^[a-z]+\.[0-9]+$ ]] || { echo "Build label must look like shaar.1: $label" >&2; exit 1; }
source scripts/engine-signing.sh

output=build/EngineSource
receipt="$output/receipt.json"
jq -e '.status == "succeeded" and (.framework.path | type == "string")' "$receipt" >/dev/null || {
  echo 'The source build has no successful framework receipt.' >&2
  exit 1
}
binary="$output/$(jq -er .framework.path "$receipt")"
[[ $(shasum -a 256 "$binary" | cut -d ' ' -f 1) == $(jq -er .framework.sha256 "$receipt") ]] || {
  echo 'Built framework changed after its receipt was written.' >&2
  exit 1
}
framework=${binary%/Versions/*/Chromium Framework}
[[ $framework != "$binary" && -d "$framework/Versions" ]] || {
  echo 'Built framework receipt has an unexpected version layout.' >&2
  exit 1
}
dsym="$(dirname "$framework")/Chromium Framework.dSYM"
entitlements="$output/source/ardia/packages/ardiacore/scripts/signing"
tree=$(jq -er .source.engineTree ThirdParty/ArdiaCore/source-build.json)
version=$(jq -er .chromium.version ThirdParty/ArdiaCore/source-build.json)

package=build/EnginePackage
rm -rf "$package"
mkdir -p "$package/stage"
cp -cR "$framework" "$package/stage/"
staged="$package/stage/Chromium Framework.framework"
[[ -d $dsym ]] && cp -cR "$dsym" "$package/"

adhoc_sign_like_upstream() {
  case "$1" in
    *"Helper (Renderer).app"|*"Helper (Aperitif Renderer).app") codesign --force --sign - --options runtime \
      --entitlements "$entitlements/renderer.entitlements" "$1" ;;
    *"Helper (GPU).app"|*"Helper (Aperitif GPU).app") codesign --force --sign - --options runtime \
      --entitlements "$entitlements/gpu.entitlements" "$1" ;;
    *) codesign --force --sign - --options runtime "$1" ;;
  esac
}
sign_engine_framework "$staged" adhoc_sign_like_upstream
codesign --verify --deep --strict "$staged"

archive="$package/ArdiaCore-${tree:0:12}-$label.tar.xz"
# Bound compression CPU use while other work continues on the build host.
if command -v xz >/dev/null 2>&1; then
  tar --no-mac-metadata -cf - -C "$package/stage" "Chromium Framework.framework" | nice -n 19 xz -T2 -9 > "$archive"
else
  nice -n 19 tar --no-mac-metadata -cJf "$archive" -C "$package/stage" "Chromium Framework.framework"
fi
checksum=$(shasum -a 256 "$archive" | cut -d ' ' -f 1)
jq -n --arg sha "$checksum" '{sha256: $sha}' > "$package/payload-pin.json"
python3 scripts/engine_payload.py --archive "$archive" --framework "$staged" \
  --pin "$package/payload-pin.json" >/dev/null || {
  echo 'Packed archive does not match the staged framework.' >&2
  exit 1
}
jq -n --arg tag "engine-$version-$label" --arg archive "$archive" --arg sha "$checksum" \
  '{releaseTag: $tag, archive: $archive, sha256: $sha}'
