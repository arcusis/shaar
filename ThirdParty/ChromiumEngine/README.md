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
a no-write dry-run plan. `--run --reference-source PATH` accepts a succeeded
pinned Chromium checkout, copies it with APFS copy-on-write into
`build/ShaarEngineSource`, installs the layer and GN hook, and builds
`chrome_framework` at background QoS with six jobs. This temporary phase-3
development mode keeps both Ardia and Shaar exports, verifies the Shaar symbols,
and runs the Swift ABI loader headlessly. Its receipt records `mode: dual-export`
and succeeds only after the loader reports ABI major 1. The independent
`--verify-framework` final-target check still rejects all `ac_*` and
`ArdiaCore*` symbols.

The current Ardia source runner and production engine pin remain in place for
the app's existing CI lane. `build/ShaarEngineSource` is a distinct ignored,
owner-bound output root. The dual-export runner reads the separate reference
tree but never writes to or cleans it.
