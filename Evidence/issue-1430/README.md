# First-tab probe bundle reliability

The standalone SwiftPM executable exited 133 with shaar.23, shaar.24, and
shaar.25. The crash report places the trap at Chromium's
`base/apple/bundle_locations.mm:74` (`CHECK(bundle)`), called from
`SetOverrideFrameworkBundlePath` during `ChromeMain`. This occurs before the
first tab is created. The `--probe-framework` argument loads Shaar's engine,
but Chromium also resolves its framework bundle from the executable's `.app`
layout. A raw `.build/debug/ShaarVerification` executable has no such layout.

The probe source did not change between shaar.23 and shaar.24. The only new
engine patch in shaar.24 was `0051-shaar-devtools-wide-dom-children.patch`,
which changes DevTools DOM child events. Running the same raw executable with
each cached framework reproduced the trap, including shaar.23. Running the
verification app bundled against each framework passed:

| Engine | Bundled exit | Receipt |
| --- | ---: | --- |
| shaar.23 | 0 | [Receipt](shaar23.json) |
| shaar.24 | 0 | [Receipt](shaar24.json) |
| shaar.25 | 0 | [Receipt](shaar25.json) |

All three receipts report `passed: true`, `nativeView: true`,
`navigationObserved: true`, and `allWindowsHidden: true`.

Build the verification app with
`scripts/bundle-app.sh --with-engine --verification`, then run
`build/Shaar Verification.app/Contents/MacOS/ShaarVerification`.
The probe now rejects a framework outside that app's `Contents/Frameworks`
before entering Chromium. The raw executable exits 1 with an actionable error
and creates no new crash report. The bundled shaar.25 run also created no new
crash report.
