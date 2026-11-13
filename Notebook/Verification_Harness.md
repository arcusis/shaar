# Verification harness

Engine probes run in `ShaarVerification`, a separate executable target. The shipped `ArcusisBrowser` executable is a thin `Shaar` target over the `ArcusisBrowser` library and contains no probe code or probe flags.

```sh
bash scripts/bundle-app.sh --with-engine --verification
```

This builds `build/Shaar Verification.app`: the same engine, resources and Info.plist as `build/Shaar.app`, with `ShaarVerification` as its executable and its own bundle identifier, `SHAAR_VERIFICATION_BUNDLE_IDENTIFIER` in `scripts/release-config.sh` (`com.arcusis.browser.verification`). macOS files crash reports, preferences and saved window state by identifier, so a crashing probe never makes the installed Shaar offer to reopen windows. `release_feed.py` rejects a config where the two identifiers match, and `engine_fixture.py` refuses to launch a harness whose Info.plist carries anything but the verification identifier. `bash scripts/test-engine.sh` builds it and passes the probe flags to it; the Source Checks workflow runs the private window fixture the same way.

`ShaarVerification` reaches app internals through `@testable import ArcusisBrowser`, so its release build passes `-Xswiftc -enable-testing` in its own scratch path, `build/swiftpm/verification`. Shipping builds use `build/swiftpm/default`, build only the `ArcusisBrowser` product and never enable testing. `scripts/check-shipping-harness.py`, run by `bundle-app.sh`, reads the verification sources and rejects those symbols, launch flags, and fixture ids in every other `Sources` directory and in the shipping executable. Its source scanner handles nested Swift block comments. The product flag `--render-preview` stays legal. Setting `SHAAR_ENGINE_TESTING` is allowed only in the engine start path.

Test-only engine entry points live in `ChromiumBridgeVerification` (`Sources/ChromiumBridgeVerification`). Only the harness and its tests import it. Each entry point returns nothing unless the runtime started in testing mode with an owned, marked disposable probe root. The trusted-click allowlist `ARCProbeTrustedClickElementAllowed`, `submitTrustedProbeClickInTabID:`, `ARCProbeRootIsOwned`, and `probeFrameworkDevToolsForProfileID:` live there. Smoke and probe launch flags dispatch from `ShaarVerificationMain`.

The separate identifier was merged in [PR #330](https://github.com/arcusis/shaar/pull/330). Shipping verification still requires `com.arcusis.browser`; the bundled Chromium framework and helpers use Shaar identifiers. Identifier separation prevents shared macOS crash/restoration attribution and preferences domains. Pending-navigation shutdown behavior still needs native Shaar verification; see [[Quit_Exit_Verification]].

The Source Checks workflow also runs a short normal-window browsing smoke on every pull request and merge-group check. It uses the same hidden verification bundle, performs an unauthenticated Google search, and opens three authored loopback pages. It checks alphabet input through the address launcher and Command-T, captures each authored page for non-black pixels, reopens a closed tab, and audits clean engine shutdown. It makes no visible window or desktop-input claim.

Tests for harness code are in `Tests/ShaarVerificationTests`.

## Space and Profile switch latency

Before the 20 scored same-profile Space switches, the probe selects each target tab once and waits for its native selection and display. It records these two cold-activation warm-up latencies separately as `spaceWarmupSamples`; they are excluded from the steady-state p95 because the first selection of each tab can include one-time WebContents activation and first-display setup. The artifact includes the discarded samples and reason. The baseline-lifecycle engine probe then measures 20 Space switches within one profile and 20 Profile switches between profiles during both initial launch and session restart. The interval starts before the native store selection and ends when the native selection audit confirms the requested tab/profile is active. The regression budget is p95 <= 100 ms. Each phase also waits for the selected native WebContents to be displayed and checks authored JavaScript snapshots for account, document, and session continuity; those correctness checks are outside the latency interval. Physical paint and energy are not measured.

The production app selection path was unchanged for this harness-only measurement. CI run [41563324753](https://github.com/arcusis/shaar/actions/runs/41563324753), baseline-lifecycle artifact `ci-engine-shard-baseline-lifecycle-41563324753-1`, measured commit `4f9a007a8648216b21f5b81b1cdcc8945f23bf58`:

| Phase | Switch | Samples | p50 | p95 | Max | 100 ms p95 budget |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| Initial | Space | 20 | 1.08 ms | 2.70 ms | 5.12 ms | Pass |
| Initial | Profile | 20 | 0.65 ms | 1.23 ms | 1.33 ms | Pass |
| Restart | Space | 20 | 1.54 ms | 2.14 ms | 2.48 ms | Pass |
| Restart | Profile | 20 | 1.27 ms | 1.93 ms | 2.40 ms | Pass |

Related: [[Source_And_Native_Verification]], [[Engine_Interop_Boundary]], [[Build_And_Run]].

## Hidden performance footprint probe

`scripts/measure-footprint.py` launches `build/Shaar Verification.app` with a marked disposable profile and a local-only static HTML fixture. It runs 1, 10 and 30 saved tabs in separate hidden app processes, waits until every fixture document is complete, and records launch-to-ready time, app-plus-descendant RSS, sampled process-tree CPU time, process count, app bundle size and Chromium Framework size. The script never opens the shipping bundle or sends desktop input.

Build the verification bundle once with `nice -n 15 bash scripts/bundle-app.sh --with-engine --verification`, then run `python3 scripts/measure-footprint.py --sample-seconds 15`. The result is written to `build/performance-baseline.json`. RSS is summed from `ps` rows for the app and its descendants; physical footprint, energy and physical paint are not measured. The verification app size includes its harness executable and must not be reported as the shipping bundle size.

`--sample-seconds` must be a positive integer; invalid durations are rejected before the verification app is launched.

Production head `9d9d675a`, two runs measured 2026-11-06 on arm64 Mac. Values are mean across runs; parentheses show the observed cross-run or sample range:

| Tabs | Launch to all pages ready | Process-tree RSS mean (range) | Idle CPU mean (range) | Mean process count |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 1.041 s (0.840–1.241) | 919.5 MiB (911.8–928.4) | 1.07% (0.97–1.17) | 7 |
| 10 | 0.607 s (0.503–0.710) | 2,034.9 MiB (2,013.2–2,047.3) | 3.13% (2.85–3.40) | 16 |
| 30 | 1.426 s (1.405–1.446) | 4,485.7 MiB (4,433.2–4,505.8) | 7.50% (2.56–12.43) | 36 |

Verification bundle: 414,748 KiB total; Chromium Framework 352,912 KiB. Two runs per tab count; the 30-tab CPU spread shows short-window load sensitivity. The verification executable is included in total app size. See [issue #1058](https://github.com/arcusis/shaar/issues/1058) for the top-win investigation and limitations.

## Production CI repair after the Shaar switch

Production `59413b3d` reproduces the non-private failures reported by merge-group
run [42105540077](https://github.com/arcusis/shaar/actions/runs/42105540077):

- Bundle-script tests fail 13 times because their temporary repository omits the
  Cocoa display notices now copied into the engine framework. Copy the actual
  notice fixtures and assert the bundled bytes; all 20 bundle tests then pass.
- `snapshotReportsDirectoryFlushFailureAfterAtomicReplacement` tries to cause a
  flush error with mode 0300, but the writer correctly restores mode 0700 first.
  Inject only the final directory flush error, keeping validation, device-flushed
  file writing, rename, and post-failure reload real.
- The site-control test crashes because its fake runtime lacks
  `setAutoPictureInPictureAllowed:tabID:` after removal of Ardia's implementation.
  Record that call in the fake and assert stale targets never dispatch it.
- Fast gates need three missing Shell catalog entries and the MPL header on the
  quit-probe script. The catalog entries match those already proposed in #1016.

Space switching had an activation feedback loop: reconciliation requests native
activation, its callback schedules reconciliation even when the selected tab is
already current, and the cycle repeats. The bridge now forwards successful native
completion, and the app restores the selected page after that completion without
reactivating it. A regression test proves an acknowledgment causes page restoration
but no second activation. Selection polling now uses 1 ms resolution with the same
five-second timeout; the full store-to-native-selection interval remains measured
against the unchanged 100 ms p95 limit. Display and account checks remain separate.

The failing CI bundle, verified against its archive digest and shaar.12 engine pin,
measured initial Space p95 61.75 ms locally (CI: 225.94 ms), versus Profile p95
1.09 ms locally (CI: 4.36 ms). With the app/bridge fix and original polling, local
Space p95 was 63.63 ms; with 1 ms polling it was 19.32 ms, Profile p95 1.24 ms.
These were 20-sample hidden-window runs using disposable profiles; the candidate
used a local debug harness with the same downloaded engine. Runner load may amplify
the main-thread scheduling delay, but is not established as the sole cause.
No budget increase or native engine build was used.

The full baseline is still distinct from those latency results. Local execution
then exposed old extension-probe assumptions: Shaar rejects an unknown extension
with a nil bridge result rather than a JavaScript error object, and the component
fixture is intentionally excluded from the user-extension list. The former is
handled without accepting a success result; the latter still fails and requires
compatible fixture coverage. Private-probe failures are outside this repair.

## Follow-up on shaar.13

Merge run [42180303400](https://github.com/arcusis/shaar/actions/runs/42180303400)
still measured Space p95 636.08 ms (first two samples 636/1206 ms), while Profile
p95 was 2.71 ms. Local activation tracing separated native submission (at most
3.16 ms) from the unnecessary main-queue wait (up to 43.45 ms). Host selections
now activate synchronously; only requests inside native event callbacks defer
until the TabStripModel notification unwinds. Nested callback tests cover both
the reentrancy guard and immediate host selection. No timer boundary or budget
changed. With the debug harness and production shaar.13, a hidden 20/20-sample
run measured Space p95 3.30 ms and Profile p95 1.73 ms. Hosted performance has
not been re-established by that local result; runner load is not proven to be
the sole source of the earlier delay.

The Swift process signal 5 was reproduced in
`privateStartPageShowsEngineControlsOnlyAfterStatusReadback`, whose base-runtime
fixture lacked `privatePrivacyStatusForContextID:completion:`. The fixture now
records the context-bound readback. The broader app/probe run exposed a missing
private-find stop selector and a stale settings-reopen expectation; those are
corrected as well. All 596 app/probe Swift Testing checks passed headlessly.

The remaining private-window readiness failure is owned by the engine work and
depends on shaar.14. The extension baseline incompatibility above is still
reported separately. These are not hidden by a passing latency measurement.
