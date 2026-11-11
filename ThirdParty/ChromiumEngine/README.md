# Shaar Chromium engine

`pin.json` identifies the Shaar engine prerelease used by app builds. The fetch
script checks the archive SHA-256 and verifies the extracted framework payload.
The bundle script rewrites the framework and helper bundle identifiers to Shaar
identifiers before signing them. The source archive's native symbols and Chromium
behavior still require separate verification before release.

`source-build.json` records the pinned Chromium inputs, Shaar-owned source layer,
ordered build patches, and their digests. Run
`bash scripts/engine-apply-patches.sh /path/to/chromium/src` before source builds.
It requires a clean checkout at the pinned commit, applies every manifest patch
with strict `git apply`, and writes `build/ShaarEngineSource/applied-patches.json`.
For a recovered, already-patched tree, run
`python3 scripts/engine_patches.py --verify-tree /path/to/chromium/src` instead.
This copies only patch-touched files to a scratch repository, reverses the
patches from last to first, compares the result with files at the pinned
Chromium commit, and writes the same receipt only if all checks pass.
The engine package script embeds this receipt in the archive. Archive fetch and
bundle verification reject a missing or incomplete patch series. The receipt
records the patch inputs and application run; it does not independently attest
the compiled binary's source provenance.

Chromium 157 DevTools is a separate `devtoolsFrontend157` record. It is not part
of the Chromium 155 `patches` list, and `0014-shaar-devtools-theme.patch` stays
on this pin. Each Shaar panel lives in
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
