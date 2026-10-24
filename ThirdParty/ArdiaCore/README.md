# ArdiaCore native API

`ArdiaCore.h`, `LICENSE`, and `NOTICE` are copied without modification from the source commit in `pin.json`. The public header is licensed under Apache-2.0. No React Native or Expo adapter is used.

The engine archive is pinned separately because upstream reuses the same engine tree across releases. Its SHA-256 matches the pinned source's `packages/ardiacore/prebuilt-engines.tsv` and GitHub's asset digest. `scripts/fetch-engine.sh` verifies the archive before extraction. The binary stays in ignored `build/`, outside Git.

Chromium contains software under multiple third-party licenses. The framework includes its resources and `chrome://credits`; those notices must remain with any distribution. Upstream's separate extension bundle, including uBlock Origin, is not fetched by this project. A distribution and source-compliance review remains part of the release milestone.

Development bundles use local ad-hoc signatures following upstream's framework staging procedure. This is not a notarized or managed company release. The pinned engine is an initial compatibility candidate, not a security-update service; shipping requires an engine update process and current security validation.
