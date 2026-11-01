# Shaar Inspector page tools

The Inspector's **Page** mode provides Tech stack, Vitals, Network, Console, Storage, Simulations and Bug report tabs in the native dock. Element picking and DOM arrow navigation are suspended in Page mode, so the page and storage editor receive normal input. The pick button returns to element inspection. Chromium's docked Developer Tools remains independent.

## Diagnostics and capture lifetime

Opening Page mode starts main-frame HTTP(S) diagnostics. Switching between Element and Page preserves capture until Inspector closes. Closing removes the navigation bootstrap, restores wrapped console/fetch/XHR functions, disconnects observers and stops frame sampling. Each collector has an owner token, preventing late cleanup from disposing a newly opened collector. Internal or inaccessible documents report unavailable diagnostics.

Technology detection reports exposed runtime versions, component/DOM markers, bootstrap data and explicitly claimed generator metadata. Missing versions remain unavailable. Detection scans at most 1,500 DOM nodes and publishes at most 20 distinct signals.

Vitals combine navigation-local LCP, INP and CLS observations with Chromium JS heap metrics, main-thread task-time deltas and requestAnimationFrame sampling. Updates occur about once per second. INP requires an observed interaction; the fallback interaction count is an estimate. Missing observations remain unavailable, including FPS in hidden documents. These diagnostics do not establish field percentile scores or whole-process CPU/memory use.

Network combines buffered resource timing from the current navigation with fetch/XHR calls observed after activation. It shows up to 500 recent rows; Console retains up to 300 bounded messages. Console object snapshots avoid invoking property getters. Resource durations become available when the browser publishes an entry, which may require consuming a fetch body. Otherwise call duration covers fetch resolution or XHR completion. Unexposed methods, statuses and transfer sizes remain explicit unknowns.

The engine bridge does not deliver DevTools events. Capture therefore omits response bodies, browser-generated headers, worker/WebSocket traffic and other frames; cross-origin timing and headers may also be restricted. Scripts run in the page world and can be modified by the page. Results are inspection aids, not trusted security evidence.

## Storage and simulations

Local/session storage lists up to 200 keys with 256-character previews. Selecting a key reads its full value, capped at 256K UTF-16 code units. Edits and deletion target the current document/origin; stale navigation results are rejected. Cookie values come from Chromium for the current URL, including HttpOnly cookies. Value edits preserve domain, path, expiry, partition, Secure, HttpOnly and SameSite settings. Opaque partition cookies remain read-only. Adding a cookie uses the current URL's defaults.

Simulation presets cover desktop/phone/tablet viewports, normal/slow-3G/offline networking, 4×/6× CPU slowdown, dark appearance, reduced motion, location, timezone and language. Preferences are stored by origin and profile. Overrides remain active when Inspector closes; the toolbar's blue simulations button resets them in one click. Location still requires site permission. Page code that cached language or media values may require reload.

Simulations use an owned DevTools session lease because the pinned bridge detaches idle callers. Chromium's own DevTools frontend can reset emulated media when opening or closing; a monitor polling every 500 ms detects the dock transition and reapplies active media preferences. No system network, location or appearance settings change.

## Local bug reports

Create bug report writes one ZIP to the profile's Downloads and opens its Library entry. The archive contains a real viewport PNG, bounded console messages, environment/viewport/simulation metadata, a page-level HAR and a capture-scope README. Cookie and authorization HAR header values are redacted by default; inclusion requires the explicit checkbox. URLs, console text and screenshot content are not redacted. Nothing is uploaded.

HAR matching requires the same URL and a nearby resource start time, avoiding attribution of later request headers to an earlier navigation. Unknown phase timings use `-1`; the total observed duration remains separate. Report staging uses owner-only directories/files and fixed member names, with a 64 MiB aggregate limit.

## Verification

`InspectorPageToolsProbe` runs on `inspector.localhost` in the full initial/restart engine fixture. It checks page input, real vitals, navigation reset, storage/cookie CRUD, ZIP contents and header redaction, viewport/media/language/timezone/geolocation effects, measured CPU/network slowdown, offline failure, session renewal, coexistence with docked DevTools, collector teardown and remembered preferences. Native windows stay unordered and offscreen. Probes never open save dialogs.

Headless contracts exercise the exact diagnostic script, real framework markers, console getter safety, fetch/XHR capture, storage edits, collector restoration and switching back to element picking. Native unit tests cover bounded/stale snapshots, owner-bound cleanup, all page tabs in both appearances and archive behavior. Opt-in public capture uses MDN, W3C and React documentation with real renderer data. Screenshots establish native layout and reported data, not physical keyboard or hover acceptance.


Public captures: [MDN vitals, light](Assets/Shaar_Inspector_Page_Tools/mdn-vitals-light.png) / [dark](Assets/Shaar_Inspector_Page_Tools/mdn-vitals-dark.png), [MDN network, light](Assets/Shaar_Inspector_Page_Tools/mdn-network-light.png) / [dark](Assets/Shaar_Inspector_Page_Tools/mdn-network-dark.png), [React markers, light](Assets/Shaar_Inspector_Page_Tools/react-tech-light.png) / [dark](Assets/Shaar_Inspector_Page_Tools/react-tech-dark.png), [W3C console, light](Assets/Shaar_Inspector_Page_Tools/wcag-console-light.png) / [dark](Assets/Shaar_Inspector_Page_Tools/wcag-console-dark.png), [storage, light](Assets/Shaar_Inspector_Page_Tools/wcag-storage-light.png) / [dark](Assets/Shaar_Inspector_Page_Tools/wcag-storage-dark.png), [simulations, light](Assets/Shaar_Inspector_Page_Tools/wcag-simulations-light.png) / [dark](Assets/Shaar_Inspector_Page_Tools/wcag-simulations-dark.png), and [report controls, light](Assets/Shaar_Inspector_Page_Tools/wcag-report-light.png) / [dark](Assets/Shaar_Inspector_Page_Tools/wcag-report-dark.png). Empty public Console and Storage views preserve the observed page state. The [capture receipt](Assets/Shaar_Inspector_Page_Tools/capture.json) records source/artifact hashes and fixture checks.

Related: [[Shaar_Inspector]], [[Shaar_Inspector_CSS]], [[Shaar_Inspector_Details]], [[Engine_Interop_Boundary]], [[Verification_Harness]]. Issue: [#366, Phase D](https://github.com/arcusis/shaar/issues/366).
