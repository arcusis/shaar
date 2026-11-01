# Developer bug reports

Create Bug Report in the site control center's Developer section saves a single ZIP to the owning profile's Downloads directory and opens Library's Downloads section. Nothing is uploaded. The archive contains a page screenshot, recent console messages, a HAR, URL/title, Shaar/Chromium/macOS versions, viewport and active simulations. Capture is bounded and document-local; no browser-wide diagnostic history is persisted.

A document-start engine page script records recent console errors, fetch/XMLHttpRequest calls and resource timings because the pinned DevTools bridge does not deliver events. The HAR therefore cannot promise complete browser network coverage. Response bodies, automatic Cookie/Set-Cookie headers, workers, other frames and cross-origin details unavailable to page scripts are omitted; unknown timing phases use -1. The archive's README and metadata preserve these limits. Console content and screenshots are not redacted.

Cookie and authorization header values are redacted in native code by default, including case variants and proxy authorization. The explicit Include cookie and authorization headers option includes values the page APIs exposed. See the [Fetch header restrictions](https://fetch.spec.whatwg.org/#forbidden-response-header-name).

`DeveloperModeProbe` emits console errors and authorized loopback requests, exports and opens both default and opted-in archives, checks member contents and redaction, checks Library registration, and captures the export section offscreen in light and dark.

Related: [[Site_Control_Center]], [[Download_Library]], [[Library_Drawer]], [[Verification_Harness]].

Offscreen captures: [Light](Assets/Developer_Bug_Reports/light.png) · [Dark](Assets/Developer_Bug_Reports/dark.png).
