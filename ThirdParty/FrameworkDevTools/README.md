# Framework DevTools bundle pins

`scripts/fetch-framework-devtools.py` downloads the pinned CRXs from the [framework-devtools-pins](https://github.com/arcusis/shaar/releases/tag/framework-devtools-pins) GitHub release into `build/cache/framework-devtools`. That directory is gitignored. The script's pins are the versions, extension IDs, and SHA-256 digests. Asset names are `{name}-{version}.crx`. A fetched archive that does not match its pin is discarded. The Chrome Web Store only serves the current package, so these release assets are what keeps an existing pin buildable after an upstream update. Add a new asset when a pin changes, and leave the old assets on the release.

Run the script with `--output build/FrameworkDevTools` to reproduce the unpacked, loopback-scoped bundles. `--download` fetches the current Web Store packages for a pin review. A digest mismatch leaves the pinned cache unchanged and writes a `.crx.candidate` file beside it.

The staged manifests retain each CRX's public-key-derived extension ID, drop the upstream update URL, and restrict host permissions, content scripts, and web-accessible resources to localhost and 127.0.0.1. The DevTools page retains its original path, with its script entry replaced by the small Shaar bootstrap. That bootstrap launches upstream code only when the inspected page URL passes `isLocalDevelopmentURL` in `Resources/FrameworkDevTools/shaar-devtools.js`. The source CRXs are unmodified.

The three upstream MIT license texts are in `licenses/` and staged in the app. Angular's CRX also includes its Material Symbols font license. See `THIRD_PARTY_NOTICES.md`.
