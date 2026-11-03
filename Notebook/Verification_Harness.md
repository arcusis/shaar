# Verification harness

Engine probes run in `ShaarVerification`, a separate executable target. The shipped `ArcusisBrowser` executable is a thin `Shaar` target over the `ArcusisBrowser` library and contains no probe code or probe flags.

```sh
bash scripts/bundle-app.sh --with-engine --verification
```

This builds `build/Shaar Verification.app`: the same engine, resources and Info.plist as `build/Shaar.app`, with `ShaarVerification` as its executable and its own bundle identifier, `SHAAR_VERIFICATION_BUNDLE_IDENTIFIER` in `scripts/release-config.sh` (`com.arcusis.browser.verification`). macOS files crash reports, preferences and saved window state by identifier, so a crashing probe never makes the installed Shaar offer to reopen windows. `release_feed.py` rejects a config where the two identifiers match, and `engine_fixture.py` refuses to launch a harness whose Info.plist carries anything but the verification identifier. `bash scripts/test-engine.sh` builds it and passes the probe flags to it; the Source Checks workflow runs the private window fixture the same way.

`ShaarVerification` reaches app internals through `@testable import ArcusisBrowser`, so its release build passes `-Xswiftc -enable-testing` in its own scratch path, `build/swiftpm/verification`. Shipping builds use `build/swiftpm/default`, build only the `ArcusisBrowser` product and never enable testing. `bundle-app.sh` rejects a shipping executable that contains the harness module, probe types or probe flags.

Test-only engine entry points live in the explicit Clang submodule `ChromiumBridge.Verification` (`Sources/ChromiumBridge/include/ChromiumBridgeVerification.h`). Only the harness and its tests import it. Their implementations remain in the bridge because they read runtime state; each returns nothing unless the runtime started in testing mode with an owned, marked disposable probe root.

The separate identifier was merged in [PR #330](https://github.com/arcusis/shaar/pull/330). Shipping verification still requires `com.arcusis.browser`; Chromium helper identifiers remain the pinned engine's `com.ardia.browser.*`. Identifier separation prevents shared macOS crash/restoration attribution and preferences domains; it does not fix the pending-navigation shutdown crash described in [[Quit_Exit_Verification]].

The Source Checks workflow also runs a short normal-window browsing smoke on every pull request and merge-group check. It uses the same hidden verification bundle, performs an unauthenticated Google search, and opens three authored loopback pages. It checks alphabet input through the address launcher and Command-T, captures each authored page for non-black pixels, reopens a closed tab, and audits clean engine shutdown. It makes no visible window or desktop-input claim.

Tests for harness code are in `Tests/ShaarVerificationTests`.

## Space and Profile switch latency

The baseline-lifecycle engine probe measures 20 Space switches within one profile and 20 Profile switches between profiles during both initial launch and session restart. The interval starts before the native store selection and ends when the native selection audit confirms the requested tab/profile is active. The regression budget is p95 <= 100 ms. Each phase also waits for the selected native WebContents to be displayed and checks authored JavaScript snapshots for account, document, and session continuity; those correctness checks are outside the latency interval. Physical paint and energy are not measured.

The production app selection path was unchanged for this harness-only measurement. CI run [41563324753](https://github.com/arcusis/shaar/actions/runs/41563324753), baseline-lifecycle artifact `ci-engine-shard-baseline-lifecycle-41563324753-1`, measured commit `4f9a007a8648216b21f5b81b1cdcc8945f23bf58`:

| Phase | Switch | Samples | p50 | p95 | Max | 100 ms p95 budget |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| Initial | Space | 20 | 1.08 ms | 2.70 ms | 5.12 ms | Pass |
| Initial | Profile | 20 | 0.65 ms | 1.23 ms | 1.33 ms | Pass |
| Restart | Space | 20 | 1.54 ms | 2.14 ms | 2.48 ms | Pass |
| Restart | Profile | 20 | 1.27 ms | 1.93 ms | 2.40 ms | Pass |

Related: [[Source_And_Native_Verification]], [[Engine_Interop_Boundary]], [[Build_And_Run]].
