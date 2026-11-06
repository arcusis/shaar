# DevTools theme look evidence for #1081

These offscreen Chromium screenshots compare the pinned DevTools token CSS with
the Shaar overrides in `0014-shaar-devtools-theme.patch`:

- `before-light.png`: upstream light tokens.
- `before-dark.png`: upstream dark tokens.
- `after-light.png`: Shaar light tokens.
- `after-dark.png`: Shaar dark tokens.

The browser and DevTools layout is a fixed structural mock showing docked tabs,
filters, a request list, details, and the Console. The colors and typography
are rendered from the actual pinned `design_system_tokens.css` before and after
the proposed patch. These images document the intended look; they are not a
built-engine or live DevTools screenshot.
