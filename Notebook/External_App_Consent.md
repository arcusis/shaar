# External application consent

Requests reaching Chromium's external-protocol consent hook enter the browser's existing native consent queue. The sheet shows application name, initiating origin, profile and scheme. Destination paths, queries, fragments, credentials and upstream prompt text stay outside the Swift/UI payload. Approval applies once, with `remember=false`; no persistent allowlist or handler registration is added.

Each request belongs to one native window, tab, profile and document generation. Unseen, malformed, duplicate, replayed or stale decisions deny. Navigation, same-URL reload, selection changes, renderer loss, tab/window closure and shutdown invalidate pending requests. Other windows cannot consume an owner's request. Existing Chromium fallback remains when the host callback is unavailable.

The pinned Chromium policy automatically permits some schemes, including `mailto`, before the consent hook. This feature does not add a universal external-link interception layer. The owned fixture uses a prompted scheme (`webcal`) and the exact `--ardia-test-external-protocol-no-launch` resolver seam. Recorder counts alone do not prove that every Chromium dispatch path is intercepted.

Run the exclusive authored acceptance mode with `.venv/bin/python scripts/engine_fixture.py --external-app-consent`. It creates an owned loopback fixture and checks initial/restart reports, canonical shared run identity, mode separation, two guarded approvals, explicit denial, stale/replayed/foreign decisions and engine/window/router cleanup. The feature report has 15 checks; the generic report currently displays zero generic checks. `localFixturesPassed=false` correctly keeps this mode separate from the full browsing baseline.

At source checkpoint `691fb9b`, actual initial/restart feature reports each passed 15 checks with two guarded approval records and nine denied requests. A separate full browsing baseline passed 458 initial and 480 restart checks. Source checks passed 232 Swift tests, 113 Python tests and strict Swift formatting. Authored normal, compact and dark sheet captures were inspected through Orca. Local receipts are in `build/Verification/external-consent-691fb9b/`; generated artifacts are not published source.

These results cover owned synthetic inputs and the native no-launch resolver, not physical keyboard/sheet-focus acceptance, all operating-system handlers, company accounts or signed distribution. Live issue: [#70](https://github.com/arcusis/shaar/issues/70).

Related: [[Media_Consent]], [[Native_Window_Ownership]], [[Source_And_Native_Verification]].
