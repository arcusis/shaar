# Build and run

Requires macOS 26+ and Xcode 26+ with Swift 6.2 or newer. The pinned development engine supports Apple silicon. The shell and unit tests build without downloading it.

```sh
swift build
swift run ArcusisBrowser
```

To build the browser with its engine (requires `curl`, `jq`, `rg`, and Python 3):

```sh
bash scripts/bundle-app.sh --with-engine
```

The script verifies the engine archive's pinned SHA-256 and compares the extracted framework payload against that archive on every fetch, including cache hits. Changed, missing or extra cached members fail before the framework path is returned for copying/signing. It then embeds framework/helpers/resources, signs nested code inside out, and verifies the local bundle. Payload equality does not establish source provenance or upstream signer identity. The result is `build/Shaar.app`, signed ad hoc for development. It is not a notarized release or registered as a default browser. Engine inputs and upstream notices are in [ThirdParty/ArdiaCore](../ThirdParty/ArdiaCore/README.md).

All bundles include the Shaar app icon, `Resources/Branding/Shaar.icns`, generated from `Branding/shaar-app-icon.svg` with `bash scripts/generate-app-icon.sh`; see [[Product_Identity]] and `Branding/DESIGN.md`. Every bundle embeds Sparkle, but development bundles carry no update feed and never check for updates; release builds and the update feed are in [[Releasing]].

`bash scripts/bundle-app.sh` without `--with-engine` builds `build/Shaar Shell.app`, a separate UI-only preview. `swift run ArcusisBrowser` also runs that preview without webpage rendering.

Related: [[Source_And_Native_Verification]], [[Releasing]].
