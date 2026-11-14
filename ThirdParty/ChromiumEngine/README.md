# Shaar Chromium engine

`pin.json` identifies the Shaar engine prerelease used by app builds. The fetch
script checks the archive SHA-256 and verifies the extracted framework payload.
The bundle script rewrites the framework and helper bundle identifiers to Shaar
identifiers before signing them. The source archive's native symbols and Chromium
behavior still require separate verification before release.

`source-build.json` records the pinned Chromium inputs, Shaar-owned source layer,
ordered build patches, and their digests. For a patch series that applies
directly to a clean pinned checkout, run
`bash scripts/engine-apply-patches.sh /path/to/chromium/src`. It uses strict
`git apply` and writes `build/ShaarEngineSource/applied-patches.json`.
The Chromium 157 builder prepares the pinned upstream stack and copies the
Shaar layer before applying the literal manifest patch list. For a recovered,
already-patched tree, run
`python3 scripts/engine_patches.py --verify-tree /path/to/chromium/src` instead.
For a Chromium 157 source tree that includes the pinned upstream stack and
copied Shaar layer, pass the builder's replay record as well:
`python3 scripts/engine_patches.py --verify-tree /path/to/chromium/src --builder-receipt /path/to/build-root/applied-patches.json`.
This copies only patch-touched files to a scratch repository, reverses the
patches from last to first, compares the result with the pinned Chromium commit
or the builder's recorded pre-Shaar baseline, and writes the same receipt only
if all checks pass.
The engine package script embeds this receipt in the archive. Archive fetch and
bundle verification reject a missing or incomplete patch series. The receipt
records the patch inputs and application run; it does not independently attest
the compiled binary's source provenance.

Chromium 157 DevTools keeps its staging metadata in `devtoolsFrontend157`.
The 157 patch list contains the applied 0064 and 0065 patches once; legacy
`0014-shaar-devtools-theme.patch` is retained only for older manifests.
Each Shaar panel lives in
`devtools-frontend/front_end/panels/shaar/<feature>/` and adds one import to
`shaar-meta.ts`. The 157 checkout copies that directory into
`third_party/devtools-frontend/src/front_end/panels/shaar`, then applies
`0064-shaar-devtools-theme-157.patch` and
`0065-shaar-devtools-frontend-registration.patch`. See
[devtools-frontend/README.md](devtools-frontend/README.md).

The macOS embedding path releases Chromium Views ownership before attaching a
selected page to Shaar. `patches/0008-native-cocoa-display.patch` restores Cocoa
compositing after that release; its [license and notices](notices/README.md) ship
inside the framework. Helper display names and icons are Shaar branded while
framework/helper binary paths stay stable for the loader.
