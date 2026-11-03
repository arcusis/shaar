# Engine step 0 native load proof

This records the temporary phase-3 dual-export build for issue #418. The only tracked C ABI header is [the Shaar layer header](../ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/public/shaar_engine.h), installed at `chrome/browser/shaar/public/shaar_engine.h` in the owned Chromium checkout. The existing production pin and Ardia-backed shipping lane remain in place during migration.

## Reproduction

From the repository root, run the Shaar-owned runner on an office Mac with the pinned Chromium source build already completed:

```sh
taskpolicy -b python3 scripts/build-shaar-engine-source.py --run \
  --reference-source /Users/david/orca/workspaces/shaar/engine-333-364/build/EngineSource/chromium_git/chromium/src \
  --relink-from-reference
```

The runner validates the pinned reference receipt and creates an APFS copy-on-write snapshot under `build/ShaarEngineSource`. GN generation and all writes occur there. Its incremental mode verifies the full GN link input set, compiles the two new Shaar objects with GN-generated commands, then links the framework with six ThinLTO jobs under background QoS. It hashes the reference receipt, `chrome/BUILD.gn`, and framework before and after the build to detect changes in that read-only reference.

## Native result

The ignored local receipt is `build/ShaarEngineSource/receipt.json`. It is the authority for stage status, framework SHA-256, export scan, Swift loader result, and reference immutability. The framework is at `build/ShaarEngineSource/chromium_git/chromium/src/out/Release_GN_arm64/Chromium Framework.framework`. The runner checks `shaar_abi_major`, `shaar_abi_minor`, `shaar_engine_create`, and `shaar_engine_release` in the linked binary, then compiles and runs a headless probe using `Sources/ShaarEngineABI/ShaarEngineABI.swift` and requires ABI major 1.

The receipt finished at `2026-11-03T20:47:07Z` with **`status: succeeded`**. Its snapshot, layer/patch, GN, build, exports, and Swift loader stages all succeeded. It records the `validated-reference-objects-relink` strategy, 22,770 verified GN link inputs, two newly compiled Shaar objects, and six ThinLTO jobs. The versioned framework binary SHA-256 is `f1bd0c17d78ae93d70e37630758a0521dd8e950a91b44350de6e8cca6b9a83d1`.

`nm -gUj` on that binary reported all four required exports:

```text
_shaar_abi_major
_shaar_abi_minor
_shaar_engine_create
_shaar_engine_release
```

The headless Swift probe log contains `shaar_loader_abi_major=1`, and the receipt records `nativeLoad.status: succeeded` with `abiMajor: 1`. The runner also checked that the read-only reference receipt, `chrome/BUILD.gn`, and framework hashes matched their pre-build values.

This is a development-only **dual-export** framework. The receipt's scan found 82 legacy `ac_*`/`ArdiaCore*` names, as expected for this migration bridge. The later final Shaar-only target must separately pass the no-`ac_*` and no-`ArdiaCore*` receipt assertion before it can replace the production pin. No framework upload, release, or pin change is part of this proof.
