# ArdiaCore native API

`ArdiaCore.h`, `ac_engine.h`, `LICENSE`, and `NOTICE` are copied without modification from the source commit in `pin.json`. The public headers are licensed under Apache-2.0. No React Native or Expo adapter is used.

`ac_engine.h` comes from `engine/chromium/src/chrome/browser/ardia/public/ac_engine.h` at that same commit (SHA-256 `09f2e4bd191f5fc593cd761e9a9443d29001e151116283b795ca5971e369f3c3`). The native service router requires ABI version 2 and resolves a fixed set of 15 calls: download list/pause/resume/cancel/remove, bookmark tree/apply/watch, history query/delete_urls/watch, site settings get/set, site data clear, and browsing data clear. It owns the single event sink shared by the download and library adapters. Profile paths come from actual loaded normal engine profiles and cannot be rebound to another profile ID; unknown profiles fail without a default fallback. Private events are discarded because the ABI labels their outer profile path with the original profile. Private-session behavior remains unverified. The adapters do not reuse the upstream JavaScript services adapter or infer a profile from a download or bookmark ID.

Chromium owns bookmark/history persistence and extension visibility. Native bookmark mutations explicitly refresh after acknowledgement because the pinned apply endpoint suppresses its own bookmark change events. Extension writes and page visits use the watched event stream. The Swift model coalesces invalidations, rejects stale responses, and keeps separate caches per profile. No upstream implementation source is copied into the application for these services.

The pinned `WindowHost::ActiveTabChanged` implementation delivers `window:didActivateTab:` while the native tab strip is notifying observers. The bridge forwards selection only for a bound tab in the window's current profile. Application clients update model selection immediately and defer tab-strip reconciliation; host profile/selection/ordering operations suppress their own activation echo. This avoids reentering tab-strip mutation from that callback. The public API does not supply an activation event for calls that leave native selection unchanged. No upstream framework modification or private API is used.

The engine archive is pinned separately because upstream reuses the same engine tree across releases. Its SHA-256 matches the pinned source's `packages/ardiacore/prebuilt-engines.tsv` and GitHub's asset digest. `scripts/fetch-engine.sh` verifies the archive before extraction. The binary stays in ignored `build/`, outside Git.

Chromium contains software under multiple third-party licenses. The framework includes its resources and `chrome://credits`; those notices must remain with any distribution. Upstream's separate extension bundle, including uBlock Origin, is not fetched by this project. A distribution and source-compliance review remains part of the release milestone.

Development bundles use local ad-hoc signatures following upstream's framework staging procedure. This is not a notarized or managed company release. The pinned engine is an initial compatibility candidate, not a security-update service; shipping requires an engine update process and current security validation.

## Source build and Profile download directories

`source-build.json` pins the Ardia source commit and engine subtree, Chromium 155, both ungoogled source commits, depot_tools, and Siso revision used by the bounded local source-build runner. The runner is opt-in:

```sh
python3 -m venv .venv
.venv/bin/python -m unittest discover -s Tests/EngineSourceBuildTests
.venv/bin/python scripts/build-engine-source.py --run
```

It creates owner-only state beneath ignored `build/EngineSource`, retains stage logs and failures, verifies exact commit, tree, archive digest, and clean state before local source reuse, caps sync at four jobs and build at six jobs, and stops when free space falls below 100 GiB. It stages pinned upstream scripts and applies checked path/job/tool substitutions; it pins Git LFS 3.8.1 by archive digest inside the owned output, keeps vpython and gclient caches there, and does not run the stale `scripts/engine-source.sh` recipe. `receipt.json` binds runner/config/script digests and records local source, Xcode and Metal Toolchain identity/version/signature/hash, GN, DEPS/CIPD, PGO, patch, framework hashes, architecture, minimum OS, and exported API evidence. This receipt is local build evidence, not signed independent provenance.

`patches/profile-download-directory.patch` adds `ac_downloads_directory_get` and `ac_downloads_directory_set` to the existing `Call(profile_dir, ...)` route. Both calls require the exact loaded normal Profile, reject shutdown/private and policy-controlled profiles, reject malformed, nonabsolute, unavailable, or unwritable directories, and return typed structured errors. Chromium `DownloadPrefs` and the Profile `PrefService` remain the persistence authority; the getter and setter compare stored and effective paths so Chromium fallback cannot be reported as success. Existing download list and target selection code remains unchanged, including its process-wide `ARDIA_DOWNLOADS_DIR` test hook; that hook is not acceptance evidence.

Compilation does not establish per-Profile runtime A/B isolation, same-directory sharing across Spaces, restart persistence, native bridge behavior, UI selection behavior, signing, notarization, or release readiness. Those require a future app bridge/native fixture and separate company release evidence.
