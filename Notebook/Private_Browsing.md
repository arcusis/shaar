# Private browsing

Private windows use the pinned engine's primary off-the-record (OTR) profile for their source profile. They share temporary cookies and storage with other private windows for that profile. Regular windows retain their persistent profiles. Closing the last private window releases its OTR profile. Private tabs and cookie allowances are not written to Shaar's workspace or preferences. Confirmed closure ends field editing and retires the optional SwiftUI root before clearing the store; see [[Private_Fixture_Readiness]].

New private tabs show a native start page with search using the source profile's selected search engine, the supported protections, and engine limitations. `about:blank` remains an internal engine placeholder; it is not the presented start page or address-field text.

## Supported protections

Before host-requested navigation, `ChromiumPrivatePrivacy.mm` applies `ac_site_settings_set` using the loaded source profile's path and `offTheRecord: true`. This selects its existing OTR profile without binding an OTR identity as a regular service profile.

- Cookies and site storage are blocked for the destination origin. Camera, microphone, location, and notifications are also blocked there, overriding inherited regular-profile exceptions. Private permission requests reaching Shaar's engine delegate are denied without presenting native prompts.
- `credentials_enable_service`, `autofill.profile_enabled`, and `autofill.credit_card_enabled` are disabled on the OTR profile before private window creation. Creation fails if the values do not read back as disabled. Regular profile preferences are unchanged.
- Native address/search submission prefers HTTPS. An explicit HTTP address requires a warning with **Try HTTPS**, **Continue with HTTP**, and **Cancel**. HTTPS failures never silently fall back. This is a native navigation guard; the engine cannot enforce it for all page links and redirects.

A content-setting failure prevents the requested navigation and reports failure. The bridge checks transient ownership before loading the page.

## Per-site cookie allowance

The private site control center reads the actual OTR cookie setting. **Allow cookies for this site** permits cookies and storage for the exact selected origin. The bridge checks tab, window, context, selected tab, and origin; stale controls cannot change a different page. **Reload after changing the switch:** Chromium caches storage access decisions in existing documents.

Private windows for the same source profile share this setting. Turning it off blocks the origin across those private windows. Closing the window that granted an allowance revokes it even if other private windows remain open. Revocation blocks access after reload but does not delete existing data; the OTR profile erases data after its last private window closes. This does not claim independent per-window cookie jars.

## Pinned engine limitations

These are unsupported defaults, not completed guarantees. The start page discloses them.

1. **No global OTR cookie/storage default.** `ac_site_settings_*` accepts HTTP(S) origins, rejects a wildcard origin, and writes primary/secondary patterns scoped to that site. There is no exposed default-content-setting setter. Guards do not cover every redirect, page link, cross-origin frame, worker, or alternate storage partition. No JavaScript replacement of storage APIs is used.
2. **CDP network settings do not survive idle detach.** The pinned `DevToolsCaller::MaybeDetachSoon` schedules `DetachIfIdle` before delivering a completed command's reply. Network-domain state disappears when the client detaches. Both `Network.setBlockedURLs` forms and `Network.setCookieControls` can acknowledge success without protecting subsequent traffic. Paired loopback probes observed an explicitly blocked tracker hostname and HTTP URL still loading after acknowledgement. Production therefore does not issue these ineffective commands or claim tracker blocking, forced third-party cookie restrictions, blanket third-party request blocking, or engine-wide HTTPS-only behavior. A bundled filter list cannot be applied through this session API. Keeping a synthetic page promise pending or polling commands would not provide a reliable persistent privacy policy.
3. **Request interception events unavailable.** The native CDP adapter consumes command replies and drops events, so `Fetch.requestPaused` cannot be handled through this public API.
4. **Referrer trimming and WebRTC local-IP limits unavailable through private-only preferences.** The host boolean allowlist excludes `enable_referrers`, `webrtc.ip_handling_policy`, and cookie-policy preferences. No string/integer preference setter is exposed. Process-wide command-line switches such as `--force-webrtc-ip-handling-policy=disable_non_proxied_udp` would also change regular browsing and are not used.
5. **Previously permitted private extensions cannot be disabled per OTR session.** Shaar does not enable extensions for private browsing or expose extension controls there. The API has no OTR-only extension-disable operation; hiding extension UI would not stop engine execution.
6. **Permission scope remains bounded.** Per-origin content settings and denied delegate requests do not establish a universal denial across every inherited permission, frame, and redirect. Browser-domain CDP permission overrides are session state, not a durable substitute for a private profile policy.

Source evidence: [pinned Ardia revision](https://github.com/mantrakp04/ardia/tree/91e17a5655519d2dc385ec8452432469232ff9af), specifically `ac_engine.cc` (`Call` and the `offTheRecord` selector), `ac_site_settings.cc` (`SiteOf`, `kTypes`, and `SetContentSettingDefaultScope`), `ardiacore_api.mm` (`IsHostPreference`, boolean setters, and primary OTR creation), and `ac_devtools_call.mm` (idle detach and reply-only dispatch). Vendored headers remain unchanged. No private engine symbols or modified engine build are used.

## Verification

`bash scripts/test-engine.sh --private-window` runs normal/OTR loopback checks in initial and restart phases. `*-private-privacy.json` separates supported behavior from observed unsupported controls: document and network cookies, local/session storage, IndexedDB, allow/revoke after reload, denied permission states, normal/OTR preference isolation, wildcard rejection, and ineffective CDP network commands. Negative capability checks do not mean tracker or HTTPS-only enforcement passed.

An authored `tracker.localhost` surrogate and the normal fixture use the owned loopback listener. No tracker endpoint is contacted and no macOS DNS setting is changed. Normal positive controls distinguish unavailable services and CSP failures from privacy behavior. The lifecycle fixture also checks allowance revocation when its granting window closes, profile isolation, cleanup, and private-history exclusion against a nonempty normal-history control.

The live private site-control model also supplies offscreen light/dark panel captures and a stale-origin rejection check. The real hidden product host saves `start-<phase>-light.png` and `start-<phase>-dark.png`. These view-only captures do not order windows or capture the desktop. Source tests cover selected-engine search, HTTP consent, tab-selection invalidation, and transient cleanup. The runner prints its owned process PID before launch observation or exact-PID cleanup signals.

Physical focus, real-site compatibility, global cookie denial, tracker blocking, WebRTC behavior, referrer trimming, extension-disable enforcement, and signed release behavior are not established by these probes.

Related: [[Site_Control_Center]], [[Engine_Interop_Boundary]], [[Source_And_Native_Verification]].
