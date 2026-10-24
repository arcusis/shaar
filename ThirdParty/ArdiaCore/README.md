# ArdiaCore native API

`ArdiaCore.h`, `ac_engine.h`, `LICENSE`, and `NOTICE` are copied without modification from the source commit in `pin.json`. The public headers are licensed under Apache-2.0. No React Native or Expo adapter is used.

`ac_engine.h` comes from `engine/chromium/src/chrome/browser/ardia/public/ac_engine.h` at that same commit (SHA-256 `09f2e4bd191f5fc593cd761e9a9443d29001e151116283b795ca5971e369f3c3`). The native download adapter requires ABI version 2 and resolves only its list, pause, resume, cancel, remove, and event-sink exports. Profile paths come from actual loaded engine profiles. It does not reuse the upstream JavaScript services adapter or infer a default profile from a download GUID.

The engine archive is pinned separately because upstream reuses the same engine tree across releases. Its SHA-256 matches the pinned source's `packages/ardiacore/prebuilt-engines.tsv` and GitHub's asset digest. `scripts/fetch-engine.sh` verifies the archive before extraction. The binary stays in ignored `build/`, outside Git.

Chromium contains software under multiple third-party licenses. The framework includes its resources and `chrome://credits`; those notices must remain with any distribution. Upstream's separate extension bundle, including uBlock Origin, is not fetched by this project. A distribution and source-compliance review remains part of the release milestone.

Development bundles use local ad-hoc signatures following upstream's framework staging procedure. This is not a notarized or managed company release. The pinned engine is an initial compatibility candidate, not a security-update service; shipping requires an engine update process and current security validation.
