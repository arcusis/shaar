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

The script verifies the Shaar engine archive's pinned SHA-256 and compares the extracted framework payload against that archive on every fetch, including cache hits. Changed, missing or extra cached members fail before the framework path is returned for copying/signing. Failed extraction removes its temporary staging directory. Locale trimming rejects symlinked or non-directory `.lproj` entries before removing unsupported locales. It then embeds framework/helpers/resources, rewrites framework and helper bundle identifiers, signs nested code inside out, and verifies the local bundle. Payload equality does not establish source provenance or upstream signer identity. The result is `build/Shaar.app`, signed ad hoc for development. It is not a notarized release or registered as a default browser. Engine inputs and notices are in [ThirdParty/ChromiumEngine](../ThirdParty/ChromiumEngine/README.md).

All bundles include the Shaar app icon, `Resources/Branding/Shaar.icns`, generated from `Branding/shaar-app-icon.svg` with `bash scripts/generate-app-icon.sh`; see [[Product_Identity]] and `Branding/DESIGN.md`. Every bundle also stages the pinned React, Vue, and Angular DevTools packages. `scripts/fetch-framework-devtools.py` downloads those CRXs from the `framework-devtools-pins` GitHub release into gitignored `build/cache/framework-devtools`, refuses a SHA-256 mismatch and unsafe output paths, and writes loopback-scoped copies into the app. The Web Store only serves the current package, so normal builds do not use it. The pins and the release assets are described in [ThirdParty/FrameworkDevTools](../ThirdParty/FrameworkDevTools/README.md). Every bundle embeds Sparkle, but development bundles carry no update feed and never check for updates; release builds and the update feed are in [[Releasing]].

`bash scripts/bundle-app.sh` without `--with-engine` builds `build/Shaar Shell.app`, a separate UI-only preview. `swift run ArcusisBrowser` also runs that preview without webpage rendering. `--with-engine --verification` builds the probe harness instead; see [[Verification_Harness]].

## Agent hosts

Machines that cannot answer a macOS password prompt export `SHAAR_MOCK_KEYCHAIN=1`. With that variable, or with `--mock-keychain`, `bundle-app.sh` writes `ShaarUseMockKeychain` into ad-hoc bundles: the shell, the engine app, debug builds, and the verification harness. The engine preview bundle always writes the key so it never shares the regular browser's Safe Storage item. `--with-updates` refuses the variable and the flag. [[Releasing]] refuses the variable before it builds, and refuses an `Info.plist` that still contains the key.

On launch the bridge reads that key and `SHAAR_MOCK_KEYCHAIN`. It enables the mock keychain only when the running bundle's signature is ad hoc, with no signing certificate and no team identifier. A Developer ID signature ignores both and uses the login keychain.

The pinned engine adds `--use-mock-keychain` only as part of `SHAAR_ENGINE_TESTING`. Ad-hoc bundles that take the mock path set that variable for the engine run. The same mode also passes `--use-fake-device-for-media-stream`, turns off renderer backgrounding and background timer throttling, and maps `trackertest.org` to `127.0.0.1`. Verification-only engine calls still require their own marked probe root. Splitting the mock keychain from those switches needs a new engine build; agent hosts do not rebuild Chromium for this.

The former dual-export source runner has been removed. [[Engine_Source_Build]] documents its historical build process; a Shaar-only source build still needs native owner verification.

Related: [[Source_And_Native_Verification]], [[Releasing]].
