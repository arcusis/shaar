# Shaar 0.2.0 publish checklist

Run from a clean checkout of the final `production` commit after all release evidence is ready. Do not publish until the exact production CI and `scripts/check-release-ci.py` pass. Passkeys are excluded from the release.

## Ordered release steps

1. **Merge in this order:** PR #1615 (shaar.36, patches 0081 and 0082), PR #1614 (0.2.0/build 2), then PR #1602 (release documents).
2. **Production CI:** confirm `CI required` and `Swift security required` are successful for the exact final `production` commit. Record its full SHA as `<production-sha>`.
3. **Release CI gate:**

   ```sh
   .venv/bin/python scripts/check-release-ci.py --repository arcusis/shaar --revision <production-sha>
   ```

   Require a zero exit status and no open code-scanning alerts.

4. **Release dry run:** save the approved English `<li>` notes as `<notes.html>`, then run:

   ```sh
   SHAAR_BUNDLE_SWIFT_JOBS=4 ~/bin/shaar-heavy bash scripts/release.sh --notes <notes.html>
   ```

   Review the signed local app, DMG, ZIP and generated `appcast.xml`; do not upload in this step.

5. **Notarize with the `shaar-notary` keychain profile:**

   ```sh
   NOTARY_PROFILE=shaar-notary SHAAR_BUNDLE_SWIFT_JOBS=4 ~/bin/shaar-heavy bash scripts/release.sh --notes <notes.html> --notarize
   ```

   This signs and notarizes the local candidate and creates the appcast. The tagged upload must be run after step 6: `release.sh --upload` requires a clean checkout of the `v0.2.0` tag, and rebuilds/notarizes that tagged source before creating a draft release.

6. **Tag:** create and push `v0.2.0` at the exact verified production commit:

   ```sh
   git tag -a v0.2.0 <production-sha> -m "Shaar 0.2.0"
   git push origin v0.2.0
   ```

7. **Upload and appcast:** from a clean checkout of the new tag, run the tagged upload:

   ```sh
   NOTARY_PROFILE=shaar-notary SHAAR_BUNDLE_SWIFT_JOBS=4 ~/bin/shaar-heavy bash scripts/release.sh --notes <notes.html> --notarize --upload
   ```

   Review and publish the resulting draft only after all gates pass. The release workflow publishes the generated `appcast.xml`; confirm the public feed and Sparkle update from v0.1.0. Do not hand-edit the feed.
8. **Website merge:** after the GitHub release is public, merge the draft `website-0.2.0` PR. Verify the published version, English notes, DMG and ZIP links, and deployed site.
9. **Engine pre-release cleanup:** remove engine pre-releases `.28`, `.30`, `.31`, `.33` first; then remove `.32`, `.34` and `.35` only after no branch, pin or release candidate references each one. Keep shaar.36 while it is the release pin.

## Release assets

- `Shaar_0.2.0_aarch64.dmg`
- `Shaar-0.2.0-macos.zip`
- `appcast.xml`

Passkey provisioning profiles and entitlements are not part of this release. Keep the website PR in draft until the app release is published.
