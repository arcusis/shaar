# Chromium 157 app release preparation

Prepared 2026-11-11 from the published **v0.1.0** app release (2026-10-31), `production`, [[Releasing]], `scripts/release.sh`, `scripts/release_feed.py`, `scripts/check-release-ci.py`, and `.github/workflows/release.yml`. The 0.2.0 release target is `engine-157.0.8103.51-shaar.36` in PR #1615, adding patch 0082 (extension tab activation) on top of shaar.35 (patch 0081, window IDs). The engine asset is **not** an app release. This document is a plan; it does not authorize a tag, release, notarization submission, or appcast change. See [[Chromium_157_Release_Notes]] and [[Chromium_157_Release_QA]].

## Release gates and proposed version

- Chromium 157 is merged; the 0.2.0 candidate targets shaar.36, pending PR #1615 and its production CI. Confirm the final production pin is shaar.36 and contains the native patches for DevTools, tab discard, website prompts, HTTPS-only, private Quit, window IDs (0081) and extension tab activation (0082). The startup mitigation and all user-facing claims still require final shipping-bundle QA. A merged app wrapper or passing focused test alone is insufficient.
- The next app version is **0.2.0, build 2**, following v0.1.0/build 1. Draft PR #1614 sets `SHAAR_BUNDLE_VERSION` and `SHAAR_BUILD_VERSION` in `scripts/release-config.sh`; `v<version>`, DMG/ZIP names, bundle Info.plist and appcast derive from them. The version bump remains preparation until merged. Do not change the Chromium engine tag as an app version.
- Save prompts and iCloud Keychain passkeys are **out of scope for 0.2.0** and must not appear in English, Hebrew or Sparkle notes. David confirmed there is no Apple provisioning profile for passkeys in this release. Do not include a passkey provisioning profile or passkey entitlements in the signed candidate.
- Complete [[Chromium_157_Release_QA]] against the exact shipping candidate. Any startup crash, unsigned nested binary, failed Gatekeeper check, missing required website prompt, or failed required CI blocks release.
- `website/src/content.ts` is a **published-release snapshot**. Update and verify its version, notes and asset links only after the app release is published; an unreleased version bump must not change the public download.

## Operator sequence from production head

Durations are planning ranges for an Office Mac with warm dependencies and a reachable Apple/GitHub service; a cold Chromium fetch, CI queue, or Apple review can add hours or days. Keep app and QA windows hidden/offscreen on this machine and use `~/bin/shaar-heavy` for heavy local commands. This wrapper takes a command directly; `SHAAR_BUNDLE_SWIFT_JOBS=4` limits its nested Swift build to four jobs. The steps that write a tag, release, or feed are for the later authorized release operation, **not this preparation PR**.

| Step | Exact action and pass condition | Typical elapsed time |
| --- | --- | --- |
| 1. Freeze source | Fetch `origin/production`, record the 40-character commit and engine pin, confirm the startup fix in the final Chromium 157 shipping bundle, inspect open blockers and the last app release with `gh release view v0.1.0 --repo arcusis/shaar`. No release if source still changes. | 5–15 min, plus merge wait |
| 2. Bump app version | Merge the separate 0.2.0/build 2 version PR onto that production head. Confirm `release_feed.py describe` yields `v0.2.0`, `Shaar_0.2.0_aarch64.dmg`, and `Shaar-0.2.0-macos.zip`, and `check-newer` finds a lower live build. | 10–20 min plus PR/CI |
| 3. Production CI | Wait for **Source checks** `CI required` on the exact final production push commit. Dispatch **Swift security** on that same `production` commit (`gh workflow run swift-security.yml --ref production`) and wait for `Swift security required`. Run `.venv/bin/python scripts/check-release-ci.py --repository arcusis/shaar --revision <40-char-production-SHA>`; zero open code-scanning alerts are required. A PR or older production run does not satisfy this gate. | 30–90 min; queue and source build vary |
| 4. Shipping QA | Build and exercise the exact hidden shipping bundle with the pinned engine, then complete the checklist. Inspect new `Shaar*.crash`/`.ips` reports. Record candidate commit, engine pin, QA evidence and failures. | 45–120 min; external account cases vary |
| 5. Notes and credential preflight | Finalize the English `<li>…</li>` notes for Sparkle and GitHub; review the Hebrew copy. On the Office Mac, check the Developer ID identity, `shaar-notary` profile and Sparkle key account `shaar` without printing private key material. Confirm no `SHAAR_PROVISIONING_PROFILE` override or `Resources/Signing/Shaar.provisionprofile` is present for this candidate. Ensure `.venv` has hash-pinned `scripts/release-requirements.txt`, SwiftPM Sparkle tools are present, `gh` can access `arcusis/shaar`, Pages uses GitHub Actions and `github-pages` permits `v*` tags. | 15–30 min |
| 6. Dry run | In a clean release checkout, write the chosen English `<li>` lines to an HTML notes file and run `SHAAR_BUNDLE_SWIFT_JOBS=4 ~/bin/shaar-heavy bash scripts/release.sh --notes <notes.html>`. This builds, signs, verifies, makes the DMG/ZIP and appcast locally; it does not notarize or upload. `--allow-unsigned-update` is diagnostic only and cannot ship. Check hashes, bundle version, signatures, Gatekeeper's expected pre-notary result, and no build-machine paths. | 20–60 min, longer if cold |
| 7. Tag and notarize | After gates pass, create/push `v0.2.0` at the exact verified production commit. In a **clean checkout of that tag**, run `SHAAR_BUNDLE_SWIFT_JOBS=4 ~/bin/shaar-heavy bash scripts/release.sh --notes <notes.html> --notarize --upload`. It checks tag and live feed, builds again, signs all Chromium helpers/framework, Sparkle and app with Developer ID/hardened runtime/timestamp, notarizes and staples the app and signed DMG, checks Gatekeeper, signs the Sparkle ZIP with EdDSA, validates the appcast, then creates a **draft** GitHub Release with DMG, ZIP, `appcast.xml`. | 30–90 min build/sign plus 10–60+ min Apple service |
| 8. Engine archive receipt gate | Before publishing the draft, obtain the receipt accompanying the **exact pinned engine archive** used in the signed app. Compare its ordered patch list and patch digests with the active Chromium 157 patch manifest at the tagged production commit. Require every expected patch exactly once, no unexpected patch, matching archive identity and hashes, and a complete successful build receipt. A missing or incomplete receipt blocks publication; the receipt format/path is being added separately. | 10–20 min once the receipt exists |
| 9. Review and publish | Inspect the draft assets and release notes after the receipt gate. Publishing the draft triggers `.github/workflows/release.yml`: exact tag/commit CI and zero alerts, three asset names, anonymous ZIP/feed download, bundle/version/signature checks, newer-than-live build, Pages URL, then Pages appcast deployment. Confirm the public feed and Sparkle update from v0.1.0. | 15–45 min plus Actions queue |
| 10. Public site | Update `website/src/content.ts` to the **published** release, verify the changelog/download links and deploy through its normal production workflow. | 10–30 min plus site CI |

`release.sh` removes `build/release` before building; retain authored notes and QA receipts elsewhere. The script rejects an existing release tag and `--upload` without `--notarize` or with an unsigned update. The Release workflow refuses an equal/older build, branch ref, draft release, prerelease, or download that is not public. Do not manually write the Pages appcast.

## Release-note accuracy audit

The published `v0.1.0` tag and current `production` have no Git merge base, so `git log v0.1.0..origin/production` alone is not a chronological release delta. This audit compared that log with production PRs merged after the published v0.1.0 release on 2026-10-31. These are provenance references for the English and Hebrew copy in [[Chromium_157_Release_Notes]], not issue numbers for users.

| Copy claim | Source and release gate |
| --- | --- |
| Chromium 157 engine | #1601, #1605, #1612; PR #1615 targets shaar.36 with patches 0081 and 0082 and must merge before the production release candidate is frozen. |
| F12 Chromium DevTools, Shaar overlay panels, retired old shell and retained Inspector | #1489, #1493, #1516, #1541, #1543, #1545, #1546, #1548, #1551, #1558, #1568, #1588, #1592, #1595, #1599. |
| Sleeping tabs and protected active/pinned/playing tabs | #1478, #1550, #1580, #1604. |
| Drag an ordinary tab between windows | #1586. |
| HTTPS upgrade, warning and per-profile setting | #1542, #1557, #1570. |
| Website permission sheet for location, notifications, MIDI and protocol handlers | #1540, #1552, #1566, #1569; native patch 0070 is in the active engine manifest. |
| Pinned/Favorite icons; pinned tab closes cleanly after renderer exit | #1479, #1547, #1572. |
| Correct profile during Space switches; Library history; no premature download error | #1585, #1591, #1593, #1475. |
| Automatic Picture in Picture when leaving video | #1476. |
| Clearer unsupported unpacked-extension message | #1553. This is a message about engine support, not a claim that unpacked loading works. |

Deliberately excluded from user-facing copy: save prompts (#1549) by release decision; iCloud Keychain passkeys (#1490) by David's decision because there is no Apple provisioning profile for 0.2.0; private Quit improvements because #1480 and #1600 add optional/verification hooks rather than a demonstrated product change; and Web Share, device choosers, screen sharing and print (#1574, #1534, #1544, #1589), which still lack feature-specific proof on the final signed shipping bundle. Shaar.35's restored capture patch 0050 and passing media/capture fixture do not alone establish the user-facing screen-sharing flow; its native window-ID fixture does not establish a new release-note feature. Probe-only, CI, security and documentation PRs do not add user-facing release claims.

## David / account dependencies

| Need | Why / owner action |
| --- | --- |
| Apple Developer team **F9Z784RA6D**, Developer ID Application certificate in Office Mac keychain | Release signing and hardened-runtime timestamp. David may need to unlock or install the certificate and confirm the signing account; never place certificate/private key in Git. |
| App Store Connect/Apple notarization credential stored as `notarytool` keychain profile `shaar-notary` (or `NOTARY_PROFILE`) | `--notarize` contacts Apple and staples app/DMG. David supplies or refreshes the Apple ID/app-specific password or API-key profile if absent/expired. |
| Sparkle EdDSA private key in Office Mac login keychain account `shaar`, matching `SHAAR_SPARKLE_PUBLIC_ED_KEY` | Installed v0.1.0 copies accept only updates signed by this key. David retrieves the backup if the key is missing; **do not generate a replacement key** for this release. |
| Bitwarden **“Arcusis/Shaar release”** entry | David supplies any missing certificate, notarization, Sparkle-key backup, and GitHub/account recovery material from this entry into the appropriate local keychain/profile. Do not paste secrets into the PR, notes, shell history, or logs. |
| GitHub `arcusis/shaar` release permissions and repository Pages configuration | `gh` must create/upload a draft and later publish it; Actions' built-in `GITHUB_TOKEN` validates assets and Pages deploys under the `github-pages` environment tag rule `v*`. No custom GitHub signing secret is required by the workflow. |
