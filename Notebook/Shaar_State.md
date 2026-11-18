# Shaar architecture and operating state

Shaar is a native macOS browser with a SwiftUI/AppKit shell and an embedded, pinned Chromium framework. The app package targets macOS 26 and Swift 6.2; the Chromium pin is `157.0.8103.51-shaar.50`. Normal engine bundles use the prebuilt, hash-pinned framework. See [[Product_Identity]], [[Build_And_Run]], [[Chromium_157_Release_Notes]] and [[Source_And_Native_Verification]].

## Modules

- `Sources/ArcusisBrowser` contains the app entry point, native window and browser presentation, browser store, command launcher, settings, library, Inspector, and feature-specific UI and coordinators.
- `Sources/BrowserCore` contains platform-independent browser state and policies: profiles, spaces, tabs, sessions, permissions, imports, sleeping tabs, persistence, and resource models.
- `Sources/ChromiumBridge` is the Objective-C++ boundary to the embedded framework. It owns runtime creation, navigation, tabs, callbacks, and engine-facing services.
- The SwiftPM target `ShaarEngineABIC` is sourced from `Sources/ShaarEngineABI/Navigation/CABI`; `ShaarStorageKeychainABIC` is sourced from `Sources/ShaarEngineABI/StorageKeychain/CABI`. `Sources/ShaarEngineABI` and `Sources/ShaarEngineC` contain the Swift and C ABI layers. `ThirdParty/ChromiumEngine/layer` and its ordered patch set carry Chromium-side changes.
- `Sources/ShaarVerification` and `Sources/ChromiumBridgeVerification` provide hidden integration probes and verification-only bridge support; they are not the shipping UI.
- `Tests` contains Swift unit and integration suites; Python checks under `scripts` cover repository contracts and CI orchestration.
- `website` contains the TypeScript static-site generator and Cloudflare Worker configuration. `Notebook` is the linked project and verification reference.

## Request and event flow

Native views send user actions to app coordinators and `BrowserStore`. BrowserCore models validate scope and policy, then app coordinators call the runtime facade through `ChromiumBridge` and the Shaar ABI where applicable. Engine callbacks enter through the bridge, become runtime events, and pass through `BrowserRuntimeEvents` and `BrowserRuntimeRouter` to update the owning store and window. Profile, window, tab, and private-session identity must remain bound across this path; stale or foreign events and replies must be rejected. See [[Browser_Architecture]], [[Engine_Interop_Boundary]], [[Engine_Module_windows-tabs]] and [[Engine_ABI_Conventions]].

## Known risks and boundaries

- The C/Objective-C++/Swift boundary has explicit handle lifetimes, asynchronous replies, and callbacks that can race close or restart. Handles are cleared when the engine stops, and once-only reply completion is shared; changes should preserve those guarantees.
- Chromium behavior depends on the exact pinned framework and native patch series. App source, fixtures, and source builds do not alone prove behavior in a shipping bundle; see [[Source_And_Native_Verification]] and [[Chromium_157_Release_QA]].
- Browser state is scoped by profile, space, native window, tab, and private session. Never infer scope from a path or untrusted identifier; see [[Profile_Space_Isolation]] and [[Private_Browsing]].
- Import and persistence code consumes on-disk data that can be malformed, truncated, or concurrently changed. Import reads and profile ownership need bounded validation; see [[Session_Durability]] and the importer implementation in `Sources/BrowserCore`.
- Website deployment credentials and public-domain routing are external operational state. Passing checks does not prove a deploy or public reachability; see [[Public_Website_Design]].

## Environments

The public site is `https://shaar.arcusis.com`, served by the `shaar-website` Cloudflare Worker. There is no staging environment. Website checks run without Cloudflare credentials. Production deployment is a separate `wrangler deploy` operation; the workflow skips deployment with a warning if `CLOUDFLARE_API_TOKEN` is absent, so deployment remains manual from a logged-in operator environment in that case. Domain and public reachability must be verified separately. See [[Public_Website_Design]] and [Website setup](../website/README.md).

The macOS app is developed and verified on macOS with Xcode; hidden probes are used for engine integration checks without bringing windows to the foreground. Normal app bundling fetches and verifies the pinned prebuilt engine. See [[Build_And_Run]], [[Verification_Harness]] and [[Chromium_157_Release_QA]].

Related: [[Project_State]], [[Notebook_Maintenance]].
