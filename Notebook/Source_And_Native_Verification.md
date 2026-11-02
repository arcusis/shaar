# Source and native verification

```sh
swift build
swift test --jobs 2
.venv/bin/python scripts/test-python.py
swift format lint --strict --recursive Package.swift Sources Tests
python3 scripts/check-license-headers.py
.venv/bin/python scripts/check-notebook-links.py
bash scripts/test-engine.sh
```

Generate native view previews without opening a window or capturing the desktop:

```sh
.build/debug/ArcusisBrowser --render-preview /tmp/arcusis-shell.png
.build/debug/ArcusisBrowser --render-preview /tmp/arcusis-command.png --command
.build/debug/ArcusisBrowser --render-preview /tmp/arcusis-compact.png --command --compact
.build/debug/ArcusisBrowser --render-preview /tmp/arcusis-space-editor.png --space-editor
.build/debug/ArcusisBrowser --render-preview /tmp/arcusis-extension-consent.png --extension-consent
.build/debug/ArcusisBrowser --render-preview /tmp/arcusis-settings.png --settings
.build/debug/ArcusisBrowser --render-preview /tmp/arcusis-profiles.png --settings --settings-profiles
.build/debug/ArcusisBrowser --render-preview /tmp/arcusis-profiles-dark.png --settings --settings-profiles --settings-dark
.build/debug/ArcusisBrowser --render-preview /tmp/arcusis-profile-editor.png --settings-profile-editor
.build/debug/ArcusisBrowser --render-preview /tmp/arcusis-profile-editor-dark.png --settings-profile-editor --settings-dark
```

The engine test builds the [[Verification_Harness]], starts an authored HTTP fixture on an ephemeral loopback port and runs the bundled engine twice. It exercises the real native store/space integration with two independent profiles and a third explicitly shared space. A component-loaded MV3 fixture checks per-profile extension storage, service workers, long-lived ports, offscreen documents, content scripts, scripted autofill into disposable fields, active-tab targeting, popup disposal, and restart recovery. Component loading is restricted to the marked temporary probe root and does not prove normal store installation. The fixture's manifest contains a public test key only; no private key is distributed.

The runner writes JSON reports, logs, and offscreen native/page/popup images to a fresh temporary directory. It never opens an existing browser profile, orders a window onscreen, enables a debugging socket, changes VPN/DNS/network settings, or signs into real services. Chromium helpers retain their sandbox. Disposable test profiles enable extension error diagnostics and use a mock keychain; they do not verify release keychain/signing behavior.

Offscreen SwiftUI/AppKit images verify native layout. Chromium's remote rendering surface may be absent from an AppKit bitmap; the test captures the authored page separately through the engine's in-process API. These images do not verify live keyboard focus, window shortcuts, external services or a signed distribution.

The hidden native host fixture also invokes real Settings menu target actions with an injected owned key-window identity. It checks exact shortcut registration, modal guards, window reuse, account/session preservation and Settings-only close routing. This is programmatic native evidence; physical keyboard/focus acceptance remains separate.

The same fixture creates an unused profile and renames a profile through the live Settings controller. It seeds nonempty authored cookie/local/session storage, checks unchanged document/native-tab/window ownership, and verifies saved profile UUIDs and names on restart. Source tests additionally cover zero-window persistence, duplicate names, stale IDs, preference bindings, and failed writes. Static profile/editor previews establish layout only, not physical keyboard or sheet-focus acceptance.

The current Source checks workflow runs Swift/Python checks, three independent private-window initial/restart fixtures, hosted sidebar captures, full engine probes, three independent Quit exit fixtures, the session-recovery probe, shipping-bundle build/signature checks, and actionlint on GitHub-hosted runners. Probe timeouts scale with `SHAAR_PROBE_TIMEOUT_SCALE`. Every repetition runs and any failure fails CI; there is no retry. [[Private_Fixture_Readiness]] records the prerequisite corrections for #310. The CI redesign is pending in [issue #334](https://github.com/arcusis/shaar/issues/334); [[Notebook_Maintenance]] documents the standalone index check for that pipeline.

Feature-specific evidence and limits: [[Media_Playback]], [[Automatic_Picture_In_Picture]], [[Picture_In_Picture_Controls]], [[Session_Durability]] and [[Abrupt_Restart_Durability]]. The download probe's paced background-transfer wait now honors the timeout scale and reports download state on timeout (#329); this is a fixture timing fix, not a product latency claim.

Related: [[Bitwarden_Compatibility]], [[Project_State]].
