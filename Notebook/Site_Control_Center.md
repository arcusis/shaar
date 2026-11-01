# Site control center

The page toolbar's site controls button opens a native popover for the selected page and its owning profile. It never opens Chromium settings pages.

- **Extensions:** the profile's pinned extensions run on the selected page; the add button opens the Chrome Web Store catalog.
- **Permissions:** microphone, camera, location, notifications, pop-ups and sound are Chromium content-setting exceptions read and written through the pinned `ac_site_settings_get` / `ac_site_settings_set` services for the site's origin in that profile. On means allow, off means block; a setting still at Chromium's ask default reads off with "Asks first".
- **Security:** Chromium's security level for the visible entry. HTTPS pages open the macOS certificate viewer (`SFCertificatePanel`). The pinned engine reports only a summary of the page's leaf certificate (Chromium 155 no longer has CDP `Network.getCertificate`, and the engine's DevTools calls do not deliver events), so Shaar reads the chain from a Network.framework TLS handshake with the site, sending no request, and shows it only when the leaf's SHA-256 matches the fingerprint Chromium reports for the page.
- **Actions:** Reload (Command-R); Hard Reload (Shift-Command-R, bypasses the cache); Clear Cache and Reload (empties the profile's HTTP cache, as Chromium's Empty Cache and Hard Reload does, then reloads bypassing the cache); Clear Cookies and Reload (deletes every cookie CDP `Network.getCookies` reports for the page URL, including partitioned ones); Clear All Site Data (`ac_site_data_clear`: cookies and storage for the registrable domain); Restart Page (discards the tab in place, releasing its renderer, then reloads it in a new process).

Reloads go through the store's reload path, so renderer-failure state and stale-target checks are shared with the toolbar and menu.

## Developer controls

The Developer section hosts [[Developer_Simulations]], [[Developer_Performance_Overlay]], [[Developer_Bug_Reports]] and [[Developer_Element_Picker]]. Feature state lives in a separate per-tab model. Expanded controls scroll within the available popover height.

## Automatic picture-in-picture

The toggle reads and writes the playback feature's per-site setting ([[Media_Playback]]): `BrowserStore.automaticPictureInPictureAllowed(for:profileID:)` and `setAutomaticPictureInPicture(_:for:profileID:)`, keyed by the page's site in its profile. Saving notifies the window engines, which apply the choice to that profile's open pages. The pinned engine has no per-site content setting for it.

## Verification

`SiteControlsProbe` runs in both engine fixture phases on an authored page at `site-controls.localhost`, a site no other probe uses. It checks permission round trips and persistence across restart, the automatic picture-in-picture toggle saving for one site only, each action's effect on cookies and storage, Restart Page without a renderer failure, and offscreen light and dark captures with live engine state. HTTPS certificate retrieval and the certificate sheet are not exercised by the fixture; the handshake and fingerprint match were checked once against a public HTTPS site.

Related: [[Automatic_Picture_In_Picture]], [[Media_Consent]], [[Renderer_Recovery]], [[Keyboard_Commands]], [[Engine_Interop_Boundary]].
