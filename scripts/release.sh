#!/bin/bash
set -euo pipefail
# Builds the Developer ID signed Shaar release: DMG, Sparkle update ZIP and appcast.
#
# Without flags this is a signing-only dry run: nothing is sent to Apple or GitHub.
#   bash scripts/release.sh --notes notes.html                      # build + sign + verify
#   bash scripts/release.sh --notes notes.html --notarize           # + notarize and staple
#   bash scripts/release.sh --notes notes.html --notarize --upload  # + draft GitHub Release
#   bash scripts/release.sh --notes notes.html --allow-unsigned-update
#                                   # dry run without the Sparkle EdDSA key
# Versions, feed and release repository: scripts/release-config.sh. Process: Notebook/Releasing.md.
cd "$(dirname "$0")/.."
source scripts/release-config.sh

usage() {
  echo 'Usage: release.sh --notes <notes.html> [--notarize] [--upload] [--allow-unsigned-update]' >&2
  exit 2
}
notes=''
notarize=false
upload=false
allow_unsigned=false
while (($#)); do
  case "$1" in
    --notes)
      if [[ -n "$notes" ]] || (($# < 2)) || [[ "$2" == --* ]]; then usage; fi
      notes="$2"
      shift 2
      ;;
    --notarize)
      if $notarize; then usage; fi
      notarize=true
      shift
      ;;
    --upload)
      if $upload; then usage; fi
      upload=true
      shift
      ;;
    --allow-unsigned-update)
      if $allow_unsigned; then usage; fi
      allow_unsigned=true
      shift
      ;;
    *) usage ;;
  esac
done
[[ -n "$notes" ]] || usage
if $upload && ! $notarize; then
  echo 'error: --upload requires --notarize; GitHub must only receive notarized assets.' >&2
  exit 2
fi
if $upload && $allow_unsigned; then
  echo 'error: --upload cannot ship an update without its Sparkle EdDSA signature.' >&2
  exit 2
fi
[[ -s "$notes" ]] || { echo "error: release notes file is missing or empty: $notes" >&2; exit 1; }

python="${PYTHON:-python3}"
feed() { "$python" scripts/release_feed.py "$@"; }
sign_identity="${SIGN_IDENTITY:-Developer ID Application: Arcusis LTD (F9Z784RA6D)}"
team_id="${TEAM_ID:-F9Z784RA6D}"
notary_profile="${NOTARY_PROFILE:-shaar-notary}"
sparkle_bin=build/swiftpm/default/artifacts/sparkle/Sparkle/bin
out=build/release
app="$out/Shaar.app"
release_names=$(feed describe)
read -r release_tag dmg_name zip_name <<< "$release_names"
dmg="$out/$dmg_name"
update_zip="$out/$zip_name"

echo "==> Releasing Shaar $SHAAR_BUNDLE_VERSION ($SHAAR_BUILD_VERSION) as $release_tag"
if ! security find-identity -v -p codesigning | grep -Fq "\"$sign_identity\""; then
  echo "error: signing identity not found in the keychain: $sign_identity" >&2
  exit 1
fi
# A placeholder key would ship an update that no installed Shaar can verify.
if $notarize || ! $allow_unsigned; then
  feed check-key
fi
if $notarize; then
  if ! xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1; then
    echo "error: notarytool profile '$notary_profile' is missing or invalid; see Notebook/Releasing.md." >&2
    exit 1
  fi
fi
if $upload; then
  gh repo view "$SHAAR_RELEASE_REPOSITORY" --json name >/dev/null
  if gh release view "$release_tag" --repo "$SHAAR_RELEASE_REPOSITORY" >/dev/null 2>&1; then
    echo "error: $SHAAR_RELEASE_REPOSITORY already has release $release_tag." >&2
    exit 1
  fi
fi

rm -rf "$out"
mkdir -p "$out/entitlements"
# Sparkle orders updates by build number. Refuse a build the live feed would never offer.
if curl --fail --silent --show-error --location "$SHAAR_FEED_URL" --output "$out/published-appcast.xml"; then
  feed check-newer --published "$out/published-appcast.xml"
else
  echo "    no published feed at $SHAAR_FEED_URL; treating this as the first release"
fi

echo '==> Building engine bundle with the update feed'
bash scripts/bundle-app.sh --with-engine --with-updates
# Move rather than copy so no ad hoc build with a live update feed stays behind.
mv build/Shaar.app "$app"

echo '==> Checking shipped binaries for build-machine paths'
# A path under the builder's home folder reveals their user name to everyone who installs Shaar.
leaks=$(find "$app" -type f \( -perm -u+x -o -name '*.dylib' \) -exec strings -a {} + 2>/dev/null \
  | grep -c "$HOME/" || true)
if ((leaks)); then
  echo "error: $leaks strings under $HOME/ found in $app." >&2
  exit 1
fi

sign() { codesign --force --options runtime --timestamp --sign "$sign_identity" "$@"; }

# Chromium's GPU and renderer helpers need com.apple.security.cs.allow-jit under the hardened
# runtime. Grant each helper exactly what the pinned upstream signature grants it.
sign_like_upstream() {
  local target="$1" upstream="$2"
  local entitlements
  entitlements="$out/entitlements/$(basename "$target").plist"
  codesign -d --entitlements - --xml "$upstream" > "$entitlements"
  sign --entitlements "$entitlements" "$target"
}

echo '==> Signing nested code inside out (Developer ID + hardened runtime)'
upstream_engine=$(bash scripts/fetch-engine.sh)
engine="$app/Contents/Frameworks/Chromium Framework.framework"
for library in "$engine"/Versions/Current/Libraries/*.dylib; do
  sign "$library"
done
for helper in "$engine"/Versions/Current/Helpers/*; do
  if [[ -d "$helper" && "$helper" == *.app ]] || [[ -f "$helper" && -x "$helper" ]]; then
    sign_like_upstream "$helper" "$upstream_engine/Versions/Current/Helpers/$(basename "$helper")"
  fi
done
sign "$engine"
# Order and flags follow Sparkle's documentation for re-signing its framework.
sparkle="$app/Contents/Frameworks/Sparkle.framework"
sign "$sparkle/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle/Versions/B/XPCServices/Downloader.xpc"
sign "$sparkle/Versions/B/Autoupdate"
sign "$sparkle/Versions/B/Updater.app"
sign "$sparkle"
sign --entitlements Resources/Signing/Shaar.entitlements "$app"

echo '==> Verifying code signature'
codesign --verify --deep --strict --verbose=2 "$app"
# An ad hoc or foreign nested signature still passes --deep --strict, yet dyld library
# validation kills it at launch and notarization rejects it. Check every piece of code.
echo "==> Asserting team $team_id and hardened runtime on all bundled code"
unsigned=0
while IFS= read -r -d '' item; do
  details=$(codesign -dvv "$item" 2>&1 || true)
  if ! grep -Fxq "TeamIdentifier=$team_id" <<< "$details" \
    || ! grep -Eq 'flags=0x[0-9a-f]+\([^)]*runtime' <<< "$details"; then
    echo "  !! ${item#"$app"/} is not signed by $team_id with the hardened runtime" >&2
    unsigned=1
  fi
done < <(
  find "$app" \( -name '*.app' -o -name '*.xpc' -o -name '*.framework' \) -print0
  find "$app" -type f -exec sh -c 'file -b "$1" | grep -q Mach-O' _ {} \; -print0
)
((unsigned == 0)) || { echo 'error: not all bundled code is release signed.' >&2; exit 1; }

notarize_and_staple() {
  echo "==> Notarizing $(basename "$1")"
  xcrun notarytool submit "$2" --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$1"
}
if $notarize; then
  ditto -c -k --keepParent "$app" "$out/notarization.zip"
  notarize_and_staple "$app" "$out/notarization.zip"
fi

echo '==> Creating DMG'
staging="$out/dmg"
mkdir -p "$staging"
ditto "$app" "$staging/Shaar.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Shaar $SHAAR_BUNDLE_VERSION" -srcfolder "$staging" -ov -format UDZO "$dmg"
rm -rf "$staging"
codesign --force --timestamp --sign "$sign_identity" "$dmg"
if $notarize; then
  notarize_and_staple "$dmg" "$dmg"
fi

echo '==> Gatekeeper assessment'
gatekeeper_ok=true
spctl -a -vv -t exec "$app" || gatekeeper_ok=false
spctl -a -vv -t open --context context:primary-signature "$dmg" || gatekeeper_ok=false
if ! $gatekeeper_ok; then
  if $notarize; then
    echo 'error: Gatekeeper rejects the notarized release.' >&2
    exit 1
  fi
  echo '    Gatekeeper rejection is expected before notarization.'
fi

echo '==> Creating Sparkle update'
ditto -c -k --sequesterRsrc --keepParent "$app" "$update_zip"
signature=''
if $allow_unsigned; then
  echo '    skipping EdDSA signature (--allow-unsigned-update); this appcast cannot ship'
else
  keychain_key=$("$sparkle_bin/generate_keys" --account "$SHAAR_SPARKLE_KEY_ACCOUNT" -p)
  if [[ "$keychain_key" != "$SHAAR_SPARKLE_PUBLIC_ED_KEY" ]]; then
    echo "error: keychain account '$SHAAR_SPARKLE_KEY_ACCOUNT' does not hold the key in release-config.sh." >&2
    exit 1
  fi
  signature=$("$sparkle_bin/sign_update" --account "$SHAAR_SPARKLE_KEY_ACCOUNT" -p "$update_zip")
fi
feed write --zip "$update_zip" --notes "$notes" --output "$out/appcast.xml" \
  ${signature:+--signature "$signature"}
if $allow_unsigned; then
  feed validate --appcast "$out/appcast.xml" --zip "$update_zip" --allow-unsigned
else
  feed validate --appcast "$out/appcast.xml" --zip "$update_zip"
fi

if $upload; then
  echo "==> Creating draft release $release_tag in $SHAAR_RELEASE_REPOSITORY"
  gh release create "$release_tag" "$dmg" "$update_zip" --repo "$SHAAR_RELEASE_REPOSITORY" \
    --draft --title "Shaar $SHAAR_BUNDLE_VERSION" --notes-file "$notes"
fi

echo ''
echo "DMG:      $dmg"
echo "Update:   $update_zip"
echo "Appcast:  $out/appcast.xml"
if $upload; then
  echo "Next: publish the draft, then commit the appcast to $SHAAR_RELEASE_REPOSITORY docs/appcast.xml."
else
  echo 'Dry run: nothing was notarized or uploaded.'
fi
