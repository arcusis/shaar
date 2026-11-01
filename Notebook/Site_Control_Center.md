# Site control center

Pending: [PR #327](https://github.com/arcusis/shaar/pull/327), issue #325, is open as of 2026-11-01. This note describes its branch, not functionality present in `production` at `295d63b`. Its media and automatic picture-in-picture dependencies (#326 and #329) have merged.

The proposed toolbar sliders button opens a native popover for the selected page and owning profile. Pinned extensions act on that page; an add button opens the Chrome Web Store. Microphone, Camera, Location, Notifications, Pop-ups and Redirects, and Sound map to origin-scoped Chromium content-setting exceptions through `ac_site_settings_get` / `ac_site_settings_set`. On means allow, off means block; an ask default reads off with “Asks first”. Automatic Picture-in-Picture instead uses the existing host-keyed per-profile API in [[Automatic_Picture_In_Picture]].

Security reflects Chromium's visible-entry security level. For HTTPS, the certificate action opens `SFCertificatePanel` only after a Network.framework TLS handshake retrieves a chain whose leaf SHA-256 matches Chromium's reported fingerprint. The handshake sends no HTTP request. Chromium 155's exposed API supplies only a leaf summary, so this additional handshake can fail; the popover then reports an error.

Actions are Reload (Command-R), Hard Reload (Shift-Command-R), Clear Cache and Reload, Clear Cookies and Reload, Clear All Site Data, and Restart Page. Cache clearing affects the whole profile's HTTP cache. Cookie clearing uses cookies reported for the page URL, including partitioned cookies. All-site-data clearing affects the registrable domain, does not reload and has no confirmation. Restart Page discards and reloads the same tab. Reloads share the existing store path and stale-target/renderer-failure guards.

The PR reports unit tests, offscreen light/dark captures and `SiteControlsProbe` checks on an isolated loopback site in both fixture phases: permission persistence, per-site auto-PiP, reload/discard behavior and cookie/storage effects. Certificate retrieval/fingerprint matching was checked separately once against a public HTTPS site; the fixture does not test the certificate sheet. Those are branch-reported results, not verification of this documentation change or merged functionality.

Related: [[Media_Consent]], [[Renderer_Recovery]], [[Keyboard_Commands]], [[Engine_Interop_Boundary]].
