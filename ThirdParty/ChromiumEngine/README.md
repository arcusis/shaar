# Shaar Chromium source layer

This directory holds Shaar-owned integration code for issue #418. The `layer/`
tree is installed at the matching path in a pinned Chromium checkout, so its
public header lands at `chrome/browser/shaar/public/shaar_engine.h`. The ordered
patch manifest in `source-build.json` hooks the layer's GN target into the macOS
`chrome_framework` and applies its export list. The files under `layer/` are
Shaar-authored MPL-2.0 code; the GN hook patch changes Chromium's BSD-licensed
build file. The pinned Chromium and ungoogled sources retain their own notices.

Migration step 0 provides only the ABI/version creation entry points and one
internal sequenced event dispatcher. Other declarations in the public header
are reserved for later modules and are not exported yet. The separate
`scripts/build-shaar-engine-source.py` validates the immutable inputs and prints
a no-write dry-run plan. Its `--run` option fails closed until source sync,
patching, GN generation, and build stages are implemented and reviewed. After a
future build, `--verify-framework` checks the exact framework binary for the
required Shaar exports and forbidden legacy exports before writing the owned
`build/ShaarEngineSource/receipt.json`.

The current Ardia source runner and production engine pin remain in place for
the app's existing CI lane. `build/ShaarEngineSource` is a distinct ignored,
owner-bound output root; no stage reads, resumes, or cleans the separate
`engine-333-364/build/EngineSource` reference tree.
