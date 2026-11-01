# Engine source build and patches

Normal bundles, CI and releases fetch the prebuilt archive pinned in `ThirdParty/ArdiaCore/pin.json`. `scripts/build-engine-source.py` is an opt-in local source-build runner; its output is not automatically used by `fetch-engine.sh` or `bundle-app.sh`.

`ThirdParty/ArdiaCore/source-build.json` pins the Ardia source commit/tree, Chromium 155.0.8059.84, ungoogled source commits, depot_tools, Siso, Git LFS archive digest and the local patch digest. Inspect the plan without starting compilation:

```sh
.venv/bin/python scripts/build-engine-source.py
.venv/bin/python -m unittest discover -s Tests/EngineSourceBuildTests
```

Passing `--run` prepares and builds under ignored, owner-only `build/EngineSource`. The runner verifies source identities and clean reusable inputs, stages checked upstream script substitutions, isolates tool caches, caps sync at four jobs and build at six, and enforces a 100 GiB free-space floor. Stage logs and `receipt.json` bind configuration, scripts, toolchain, patch and resulting framework hashes; they are local evidence, not signed independent provenance.

The reviewed `patches/profile-download-directory.patch` adds `ac_downloads_directory_get` and `ac_downloads_directory_set` for exact loaded normal profiles. It rejects private/shutdown/policy-controlled profiles and unusable directory paths. Chromium `DownloadPrefs` and its `PrefService` remain the authority. This patch is not present in the prebuilt archive, and Shaar has no app bridge or picker for it. Compilation and runner tests do not prove per-profile runtime download isolation, restart persistence, UI behavior, signing or release readiness.

Further source-build experiments on feature branches must be documented as pending until merged. The pinned engine's pending-navigation Quit crash is separate from this download-directory patch; see [[Quit_Exit_Verification]]. Upstream notices and detailed source inputs: [ArdiaCore README](../ThirdParty/ArdiaCore/README.md).

Related: [[Build_And_Run]], [[Engine_Interop_Boundary]], [[Download_Library]].
