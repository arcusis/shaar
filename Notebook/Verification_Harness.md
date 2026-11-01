# Verification harness

Engine probes run in `ShaarVerification`, a separate executable target. The shipped `ArcusisBrowser` executable is a thin `Shaar` target over the `ArcusisBrowser` library and contains no probe code or probe flags.

```sh
bash scripts/bundle-app.sh --with-engine --verification
```

This builds `build/Shaar Verification.app`: the same engine, resources and Info.plist as `build/Shaar.app`, with `ShaarVerification` as its executable and its own bundle identifier, `SHAAR_VERIFICATION_BUNDLE_IDENTIFIER` in `scripts/release-config.sh` (`com.arcusis.browser.verification`). macOS files crash reports, preferences and saved window state by identifier, so a crashing probe never makes the installed Shaar offer to reopen windows. `release_feed.py` rejects a config where the two identifiers match, and `engine_fixture.py` refuses to launch a harness whose Info.plist carries anything but the verification identifier. `bash scripts/test-engine.sh` builds it and passes the probe flags to it; the Source Checks workflow runs the private window fixture the same way.

`ShaarVerification` reaches app internals through `@testable import ArcusisBrowser`, so its release build passes `-Xswiftc -enable-testing` in its own scratch path, `build/swiftpm/verification`. Shipping builds use `build/swiftpm/default`, build only the `ArcusisBrowser` product and never enable testing. `bundle-app.sh` rejects a shipping executable that contains the harness module, probe types or probe flags.

Test-only engine entry points live in the explicit Clang submodule `ChromiumBridge.Verification` (`Sources/ChromiumBridge/include/ChromiumBridgeVerification.h`). Only the harness and its tests import it. Their implementations remain in the bridge because they read runtime state; each returns nothing unless the runtime started in testing mode with an owned, marked disposable probe root.

Tests for harness code are in `Tests/ShaarVerificationTests`.

Related: [[Source_And_Native_Verification]], [[Engine_Interop_Boundary]], [[Build_And_Run]].
