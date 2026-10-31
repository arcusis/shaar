# Releasing

Shaar updates itself with Sparkle 2 (pinned in `Package.swift`), the same way as Zerm: an appcast on GitHub Pages and the update download on GitHub Releases. `arcusis/shaar` is internal, so Sparkle cannot read its Pages or assets without credentials. The feed and downloads live in the public repository `arcusis/shaar-releases`: Pages serves `docs/appcast.xml` from its default branch, and its Releases hold `Shaar_<version>_aarch64.dmg` and `Shaar-<version>-macos.zip`.

Versions, bundle id, feed URL, release repository and the Sparkle public key are constants in `scripts/release-config.sh`. `bundle-app.sh`, `release.sh`, `release_feed.py` and the Release workflow all read that file.

## Development and release bundles

Every bundle embeds `Sparkle.framework`, because the executable links it, plus its MIT license in `Contents/Resources/Sparkle`. Only `bundle-app.sh --with-updates`, which `release.sh` uses, writes `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks` and `SUEnableInstallerLauncherService`. The app starts Sparkle only when the bundle names an HTTPS feed and a real 32-byte Ed25519 public key (`UpdateFeedConfiguration`). Development bundles, the shell preview, probes and tests never check. Their "Check for Updates…" item in the Shaar menu stays disabled.

## One-time setup

1. Create the public repository `arcusis/shaar-releases` and enable Pages from `/docs` on its default branch.
2. Build once so SwiftPM fetches Sparkle's tools, then run `build/swiftpm/default/artifacts/sparkle/Sparkle/bin/generate_keys --account shaar`. Put the printed public key in `SHAAR_SPARKLE_PUBLIC_ED_KEY`. The private key stays in the login keychain. Back it up privately with `generate_keys --account shaar -x <file>`. Without it, existing installs cannot accept any later update.
3. Store notarization credentials as the keychain profile `shaar-notary`:
   `xcrun notarytool store-credentials shaar-notary --key <AuthKey.p8> --key-id <KEY-ID> --issuer <ISSUER-UUID>`.
4. The release Mac needs `Developer ID Application: Arcusis LTD (F9Z784RA6D)` in its keychain.

## Cutting a release

1. Raise `SHAAR_BUNDLE_VERSION` (Major.Minor.Patch, which also sets the tag `v<version>`). Raise `SHAAR_BUILD_VERSION` too: Sparkle orders updates by it, and `release.sh` refuses a build that is not above the live feed's.
2. Write the release notes as `<li>` lines in an HTML file.
3. Dry run: `bash scripts/release.sh --notes notes.html`. Add `--allow-unsigned-update` when the EdDSA key is not on this Mac.
4. Real run: `bash scripts/release.sh --notes notes.html --notarize --upload`. This notarizes and staples both the app and the DMG, then creates a **draft** release in `shaar-releases` with both assets.
5. Tag the source in `arcusis/shaar` with the same `v<version>`, then publish the draft.
6. Commit `build/release/appcast.xml` to `shaar-releases` as `docs/appcast.xml`. Publish the release first. Otherwise clients see the update before its download exists.
7. Run the Release workflow (`workflow_dispatch`, input `tag`) in `arcusis/shaar`. It checks the tag format and the exact assets. It downloads the live feed and the ZIP without credentials, then checks them against the tagged `release-config.sh`: title, versions, minimum system, enclosure URL and length, EdDSA signature, and the ZIP's bundle id, versions, feed and key.

Only `--notarize` contacts Apple, and only `--upload` writes to GitHub. `--upload` requires `--notarize` and a signed update.

## Signing

`release.sh` builds with `bundle-app.sh --with-engine --with-updates` and moves the bundle to `build/release/Shaar.app`, so no ad hoc bundle with a live feed is left behind. It then fails if any shipped binary contains a path under the builder's home folder. Next it re-signs inside out with Developer ID, the hardened runtime and a secure timestamp:

- Chromium libraries, helpers, then the framework. Each helper gets exactly the entitlements of the pinned upstream signature. For engine `0fd438ac5e78` that is `com.apple.security.cs.allow-jit` on the GPU and Renderer helpers (including the Aperitif ones) and none on the others. None of them carries `allow-unsigned-executable-memory`.
- Sparkle in the order of its documentation: Installer.xpc, Downloader.xpc (keeps its entitlements), Autoupdate, Updater.app, then the framework.
- The app gets `Resources/Signing/Shaar.entitlements`: camera, microphone and location, which the hardened runtime otherwise blocks for website requests.

After signing, the script runs `codesign --verify --deep --strict`. It also checks that every bundle and Mach-O file has team `F9Z784RA6D` and the runtime flag, because an ad hoc nested signature still passes `--deep --strict`. Then it builds the DMG and the ditto ZIP. It signs the ZIP with `sign_update --account shaar` after checking that the keychain key matches `release-config.sh`, then writes and validates the single-item appcast.

## Verification on 2026-10-31

Dry run, Developer ID signed, not notarized, unsigned update: `codesign --verify --deep --strict` passed, and the team/runtime assertion passed. `spctl -a -vv` rejected both the app and the DMG with `source=Unnotarized Developer ID`, which is expected before notarization. The baseline engine probe (`scripts/engine_fixture.py`) ran against that hardened-runtime copy and passed 530 checks in both the initial and restart phases. Notarization, stapling, EdDSA signing and an end-to-end Sparkle update have not been exercised yet.

Related: [[Build_And_Run]], [[Product_Identity]].
