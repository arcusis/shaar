#!/bin/bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Package a verified Shaar-only framework for issue #418 CI testing.
set -euo pipefail
cd "$(dirname "$0")/.."
label=${1:?usage: package-shaar-engine-test.sh shaar.N}
[[ $label =~ ^shaar\.[1-9][0-9]*$ ]] || { echo "Invalid test build label: $label" >&2; exit 2; }
source scripts/engine-signing.sh

output=build/ShaarEngineSource
receipt="$output/receipt.json"
tests=build/layer-errors/app-switch-gtest.json
first_tab=build/layer-errors/shaar-first-tab.json
version=$(jq -er .chromium.version ThirdParty/ChromiumEngine/source-build.json)
tag="engine-$version-$label"
name="ShaarEngine-$version-$label"

jq -e '.sourceKind == "shaar" and .mode == "final" and
  .status == "succeeded" and (.framework.exports.required | length) >= 26 and
  .framework.exports.legacyFound == []' \
  "$receipt" >/dev/null
python3 scripts/engine_patches.py --verify-receipt "$output/applied-patches.json"
[[ $(shasum -a 256 ThirdParty/ChromiumEngine/source-build.json | cut -d ' ' -f 1) == \
   $(jq -er .configSha256 "$receipt") ]] || { echo 'Source config changed after verification.' >&2; exit 1; }
[[ $(jq -er .layerSha256 "$receipt") == \
   $(jq -er .layer.sha256 ThirdParty/ChromiumEngine/source-build.json) ]] || {
  echo 'Layer changed after verification.' >&2; exit 1;
}
jq -e '.failures == 0 and .tests >= 84' "$tests" >/dev/null
jq -e '.passed == true and .backend == "shaar" and .nativeView == true and
  .navigationObserved == true and .allWindowsHidden == true' "$first_tab" >/dev/null
grep -qx 'shaar_loader_abi_major=1' "$output/swift-probe.log"

relative=$(jq -er .framework.binary "$receipt")
binary="$output/$relative"
framework=${binary%/Versions/*/Chromium Framework}
[[ $framework != "$binary" && -d "$framework/Versions" && $framework == "$output/"* ]] || {
  echo 'Framework path is outside the owned source output.' >&2; exit 1;
}
source_sha=$(jq -er .framework.sha256 "$receipt")
[[ $(shasum -a 256 "$binary" | cut -d ' ' -f 1) == "$source_sha" ]] || {
  echo 'Framework binary changed after export verification.' >&2; exit 1;
}
if /usr/bin/nm -a "$binary" | grep -Eiq '(_ac_|ardia)'; then
  echo 'Framework still contains an Ardia-named symbol.' >&2; exit 1
fi

package=build/ShaarEnginePackage
rm -rf "$package"
mkdir -p "$package/stage"
ditto "$framework" "$package/stage/Chromium Framework.framework"
cp "$output/applied-patches.json" "$package/stage/applied-patches.json"
staged="$package/stage/Chromium Framework.framework"
python3 scripts/trim-engine-locales.py "$staged" > "$package/resource-trim.json"
python3 scripts/rebrand-engine-framework.py "$staged"
adhoc_sign_test() {
  codesign --force --timestamp=none --sign - "$1"
}
sign_engine_framework "$staged" adhoc_sign_test
codesign --verify --deep --strict "$staged"

archive="$package/$name.tar.xz"
if command -v xz >/dev/null 2>&1; then
  tar --no-mac-metadata -cf - -C "$package/stage" 'Chromium Framework.framework' applied-patches.json |
    nice -n 19 xz -T2 -9 > "$archive"
else
  nice -n 19 tar --no-mac-metadata -cJf "$archive" -C "$package/stage" \
    'Chromium Framework.framework' applied-patches.json
fi
python3 scripts/engine_patches.py --verify-archive "$archive"
archive_sha=$(shasum -a 256 "$archive" | cut -d ' ' -f 1)
printf '%s  %s\n' "$archive_sha" "$(basename "$archive")" > "$archive.sha256"
jq -n --arg sha "$archive_sha" '{sha256: $sha}' > "$package/payload-pin.json"
python3 scripts/engine_payload.py --archive "$archive" --framework "$staged" \
  --pin "$package/payload-pin.json" > "$package/payload-check.json"

jq -n --arg tag "$tag" --arg sha "$archive_sha" --arg sourceSha "$source_sha" \
  --arg signedSha "$(shasum -a 256 "$staged/Versions/Current/Chromium Framework" | cut -d ' ' -f 1)" \
  --arg revision "$(git rev-parse HEAD)" --slurpfile source "$receipt" \
  --slurpfile tests "$tests" --slurpfile firstTab "$first_tab" \
  --slurpfile resourceTrim "$package/resource-trim.json" \
  '{schemaVersion:1,sourceKind:"shaar",purpose:"test build for #418",releaseTag:$tag,
    sourceRevision:$revision,archiveSha256:$sha,sourceBinarySha256:$sourceSha,
    signedBinarySha256:$signedSha,sourceBuild:$source[0],
    layerTests:{passed:$tests[0].tests,failed:$tests[0].failures},firstTab:$firstTab[0],
    resourceTrim:$resourceTrim[0]}' \
  > "$package/$name.receipt.json"
printf '%s\n%s\n%s\n' "$archive" "$archive.sha256" "$package/$name.receipt.json"
