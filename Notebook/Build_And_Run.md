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

The script verifies the engine archive's pinned SHA-256 and compares the extracted framework payload against that archive on every fetch, including cache hits. Changed, missing or extra cached members fail before the framework path is returned for copying/signing. It then embeds framework/helpers/resources, signs nested code inside out, and verifies the local bundle. Payload equality does not establish source provenance or upstream signer identity. The result is `build/Arcusis Browser.app`, signed ad hoc for development. It is not a notarized release or registered as a default browser. Engine inputs and upstream notices are in [ThirdParty/ArdiaCore](../ThirdParty/ArdiaCore/README.md).

All bundles include the company Arcusis icon from `Resources/Branding`. Its source PNG matches the company website's `public/images/logo-green-icon.png`; regenerate the bundled ICNS with `bash scripts/generate-app-icon.sh`. Development bundles do not automatically update. Keep feedback builds at distinct paths when another preview is running.

`bash scripts/bundle-app.sh` without `--with-engine` builds `build/Arcusis Browser Shell.app`, a separate UI-only preview. `swift run ArcusisBrowser` also runs that preview without webpage rendering.

Related: [[Source_And_Native_Verification]].
