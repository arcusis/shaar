# Shaar Chromium engine

`pin.json` identifies the Shaar engine prerelease used by app builds. The fetch
script checks the archive SHA-256 and verifies the extracted framework payload.
The bundle script rewrites the framework and helper bundle identifiers to Shaar
identifiers before signing them. The source archive's native symbols and Chromium
behavior still require separate verification before release.

`source-build.json` records the pinned Chromium inputs, Shaar-owned source layer,
ordered build patches, and their digests. The previous source runner depended on
a dual-export framework and has been removed. A Shaar-only source build and native
module checks remain future work; this migration does not build Chromium locally.
