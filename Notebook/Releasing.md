# Releasing

Shaar updates itself with Sparkle 2 (pinned in `Package.swift`). The update feed is an appcast served by GitHub Pages for `arcusis/shaar`, and the downloads are GitHub Release assets of the same repository. Sparkle reads both without credentials. Each release has three assets: `Shaar_<version>_aarch64.dmg`, the Sparkle update `Shaar-<version>-macos.zip`, and `appcast.xml`. The Release workflow publishes the feed through a Pages Actions deployment, so it needs no branch or directory in the repository.

Versions, bundle id, feed URL, release repository and the Sparkle public key are constants in `scripts/release-config.sh`. `bundle-app.sh`, `release.sh`, `release_feed.py` and the Release workflow all read that file. `release_feed.py` validates it before any script sources it. Every value may use only letters, digits and `. _ : / + = -`.

## Development and release bundles

The executable links Sparkle, so every bundle embeds `Sparkle.framework` and Sparkle's license in `Contents/Resources/Sparkle/LICENSE`. Sparkle itself is MIT licensed. Its license file also covers bundled code under other terms: bsdiff 4.3 (BSD 2-clause), sais-lite (MIT) and orlp/ed25519 (zlib).

Only `bundle-app.sh --with-engine --with-updates` in the release configuration writes `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks` and `SUEnableInstallerLauncherService`. `release.sh` is its only caller. The app starts Sparkle only when the bundle names an HTTPS feed and a real 32-byte Ed25519 public key (`UpdateFeed.isConfigured`). Development bundles, the shell preview, probes and tests never check for updates, and their "Check for Updates…" item in the Shaar menu stays disabled.

## One-time setup

1. In repository settings, set Pages → Source to **GitHub Actions**. In Environments → `github-pages`, add the deployment tag rule `v*`, because the workflow deploys from the release tag ref.
2. Create `.venv` and install the hash-pinned checker dependencies:
   `python3 -m venv .venv && .venv/bin/python -m pip install --require-hashes --only-binary=:all: -r scripts/release-requirements.txt`.
3. Build once so SwiftPM fetches Sparkle's tools. Then run `build/swiftpm/default/artifacts/sparkle/Sparkle/bin/generate_keys --account <SHAAR_SPARKLE_KEY_ACCOUNT>` and put the printed public key in `SHAAR_SPARKLE_PUBLIC_ED_KEY`. The private key stays in the login keychain. Keep a private backup of it (`generate_keys -x`): without it, installed copies can never accept another update.
4. Store notarization credentials as a `notarytool` keychain profile, and pass its name as `NOTARY_PROFILE` when the default in `release.sh` does not match.
5. The release Mac needs the `Developer ID Application: Arcusis LTD (F9Z784RA6D)` certificate.

## Cutting a release

1. Raise `SHAAR_BUNDLE_VERSION` (Major.Minor.Patch, which also sets the tag `v<version>`) and `SHAAR_BUILD_VERSION`. Sparkle orders updates by the build number.
2. Merge the change, then tag `v<version>` and push the tag.
3. Write the release notes as `<li>` lines in an HTML file.
4. Dry run: `bash scripts/release.sh --notes notes.html`. Add `--allow-unsigned-update` when the EdDSA key is not on this Mac.
5. Real run, from a clean checkout of the tag: `bash scripts/release.sh --notes notes.html --notarize --upload`. It notarizes and staples the app and the DMG, then creates a **draft** release on the existing tag with all three assets.
6. Publish the draft. That runs the Release workflow:
   1. It requires a tag ref in `v<Major.Minor.Patch>` form, a published release that is not a prerelease, and all three exact assets.
   2. It downloads `appcast.xml` and the ZIP without credentials, exactly as Sparkle clients do, and checks them against the tagged `release-config.sh`. The checks cover the title, versions, minimum system, enclosure URL and length, the ZIP's bundle id, versions, feed and key, and the Ed25519 signature over the ZIP bytes, verified with `SUPublicEDKey`.
   3. It requires a build number above the live feed's. Only an HTTP 404 (no feed yet) passes without one, so re-running an older tag cannot roll the feed back.
   4. It checks that Pages serves the configured feed URL, then deploys that `appcast.xml`.

   The feed therefore changes only after its download is public.

To re-validate or re-deploy by hand, dispatch the workflow on the tag ref: `gh workflow run release.yml --ref v<version>`. A run on a branch fails.

Only `--notarize` contacts Apple, and only `--upload` writes to GitHub. `--upload` requires `--notarize` and a signed update.

## Signing

`release.sh` builds with `bundle-app.sh --with-engine --with-updates` and moves the bundle to `build/release/Shaar.app`, so no ad hoc bundle with a live feed stays behind. It fails if a shipped binary contains a path under the builder's home folder. It then re-signs inside out with Developer ID, the hardened runtime and a secure timestamp:

- Chromium libraries, helpers, then the framework, in the same order as development bundles (`scripts/engine-signing.sh`). Each helper gets exactly the entitlements of the pinned upstream signature. The GPU and Renderer helpers carry `com.apple.security.cs.allow-jit`. No helper carries `allow-unsigned-executable-memory`.
- Sparkle in the order of its documentation: Installer.xpc, Downloader.xpc (keeps its entitlements), Autoupdate, Updater.app, then the framework.
- The app gets `Resources/Signing/Shaar.entitlements`: camera, microphone and location. The hardened runtime blocks these for website requests without the entitlements. Bluetooth has no hardened runtime entitlement; its Info.plist usage string is enough.

Next, `codesign --verify --deep --strict` runs. A check that every bundle and Mach-O file carries team `F9Z784RA6D` with the runtime flag follows, because an ad hoc nested signature still passes `--deep --strict`. The script then builds the DMG and the ditto ZIP. It confirms the keychain key matches `SHAAR_SPARKLE_PUBLIC_ED_KEY` and signs the ZIP with `sign_update`. Last, it writes the single-item appcast and runs the workflow's appcast, ZIP and signature checks on it.

Related: [[Build_And_Run]], [[Product_Identity]].
