# Engine source build and patches

Normal bundles, CI and releases fetch the prebuilt archive pinned in `ThirdParty/ArdiaCore/pin.json`. `scripts/build-engine-source.py` is an opt-in local source-build runner; its output is not automatically used by `fetch-engine.sh` or `bundle-app.sh`.

`ThirdParty/ArdiaCore/source-build.json` pins the Ardia source commit/tree, Chromium 155.0.8059.84, ungoogled source commits, depot_tools, Siso, Git LFS archive digest and the local patch digest. Inspect the plan without starting compilation:

```sh
.venv/bin/python scripts/build-engine-source.py
.venv/bin/python -m unittest discover -s Tests/EngineSourceBuildTests
```

Passing `--run` prepares and builds under ignored, owner-only `build/EngineSource`. The runner verifies source identities and clean reusable inputs, stages checked upstream script substitutions, isolates tool caches, caps sync at four jobs and build at six, and enforces a 100 GiB free-space floor. Stage logs and `receipt.json` bind configuration, scripts, toolchain, patch and resulting framework hashes; they are local evidence, not signed independent provenance.

The DevTools frontend overlay staging script rejects symlinked source files so staging cannot copy content from outside the pinned overlay.

The ABI contract checker requires source-build patch paths to remain inside the repository before reading their pinned contents.
Symlink loops in those paths are reported as invalid repository paths rather than escaping as a pathlib traceback.
The engine payload CLI reports non-UTF-8 pin files as malformed through its machine-readable failure report.
The test-engine fetcher rejects symlinked cached archive paths before invoking `gh`.
The pinned engine fetcher refuses symlinks at its archive and `.partial` cache paths before invoking `curl`.
The engine payload verifier also rejects symlink cycles even when archive and extracted framework entries match exactly.

The reviewed `patches/profile-download-directory.patch` adds `ac_downloads_directory_get` and `ac_downloads_directory_set` for exact loaded normal profiles. It rejects private/shutdown/policy-controlled profiles and unusable directory paths. Chromium `DownloadPrefs` and its `PrefService` remain the authority. This patch is not present in the prebuilt archive. Shaar now persists a per-profile folder choice and can scan it in Library, but the shipped engine still does not apply the choice to browser downloads. Compilation and runner tests do not prove per-profile runtime download isolation, restart persistence, UI behavior, signing or release readiness.

Further source-build experiments on feature branches must be documented as pending until merged. The pinned engine's pending-navigation Quit crash is separate from this download-directory patch; see [[Quit_Exit_Verification]]. Upstream notices and detailed source inputs: [ArdiaCore README](../ThirdParty/ArdiaCore/README.md).

Related: [[Build_And_Run]], [[Engine_Interop_Boundary]], [[Download_Library]].
