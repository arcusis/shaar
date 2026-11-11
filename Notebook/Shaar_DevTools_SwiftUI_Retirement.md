# SwiftUI DevTools retirement

The SwiftUI DevTools shell and panels are retired. The grouped removals shipped in PRs #1592, #1595, and #1599. Shaar Inspector remains available from the browser, and F12 / Option-Command-I open Chromium's docked DevTools.

## Feature destinations

- Viewports emulation and network rules are provided by the Chromium DevTools overlay.
- Copy for agent is provided by the Chromium DevTools overlay.
- Framework inspection is provided by the React, Vue, and Angular extensions in the overlay.
- Chromium's built-in panels provide Console, Network, Application, Sources, Performance, Memory, Coverage, and the standard Elements and diagnostics tools.
- The Shaar-only repro capture and export flow, WebKit comparison, custom panel shell and layout preferences, and other SwiftUI-only panel workflows are retired without a replacement.
- Shaar Inspector remains separate, including its DOM and style inspection, source actions, and agent assistance.

Keep hidden verification in `ShaarVerification`, outside the shipping target. The F12 route smoke must prove that the hidden Chromium DevTools dock opens while all windows stay hidden. Inspector probes continue to cover Shaar Inspector. Test the shipping bundle before claiming runtime support; fixtures and transport tests alone are insufficient.

## Native overlay boundaries

The Chromium overlay owns the DevTools UI and panel interactions. The app keeps only its F12 / Option-Command-I routing and Shaar Inspector integration. Do not restore SwiftUI panel routes, settings, or persisted panel layout defaults. Native Chromium behavior stays in the pinned engine patches; app-side code must not recreate web APIs with injected page scripts or page-visible signaling.

Related: [[Shaar_DevTools_Frontend_Panel]], [[Shaar_Inspector]], [[Engine_Module_devtools]].
