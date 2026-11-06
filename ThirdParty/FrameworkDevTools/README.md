# Framework DevTools bundle pins

The official Chrome Web Store CRXs in `archives/` are the inputs to `scripts/fetch-framework-devtools.py`. Their exact versions, IDs and SHA-256 digests are in that script. Run it with `--output build/FrameworkDevTools` to reproduce the unpacked, loopback-scoped bundles. Run with `--download` to fetch the current official CRXs; a version change fails the pin check until the new package is reviewed and its pin is updated.

The staged manifests retain each CRX's public-key-derived extension ID, drop the upstream update URL, and restrict host permissions, content scripts, and web-accessible resources to localhost and 127.0.0.1. The DevTools page retains its original path, with its script entry replaced by the small Shaar bootstrap. That bootstrap launches upstream code only when the inspected page URL passes `isLocalDevelopmentURL` in `Resources/FrameworkDevTools/shaar-devtools.js`. The source CRXs are unmodified.

The three upstream MIT license texts are in `licenses/` and staged in the app. Angular's CRX also includes its Material Symbols font license. See `THIRD_PARTY_NOTICES.md`.
