# Inspector component, accessibility and asset details

The native Inspector adds **Component**, **A11y** and **Assets** tabs alongside Design and CSS. Each reads the locked element in its owning tab, profile and window. Selection/document changes invalidate pending results, and closing clears snapshots and page listeners. Copy actions appear on hover and keyboard focus. The compact layout keeps native controls and monospace values in both appearances.

## Exposed component data

React reads the current Fiber branch, including alternate branches after updates, and builds a bounded component hierarchy. Props, class state and raw hook state slots come from runtime metadata. Hook names and custom-hook structure are not inferred. Vue reads component hierarchy, props, data and exposed setup state. Development source fields are shown when present; original names and source locations cannot be recovered from an opaque or minified build.

Svelte reads DOM source ancestry and captures `SvelteRegisterComponent` development registrations while Inspector is active. A captured registration can expose props and `$capture_state`; a component mounted before collection may expose only source metadata. Svelte 5 signal state is not reconstructed from compiled code. React 18.3.1, Vue 3.5.22 and Svelte 4.2.20 development runtimes are exercised by the authored fixture; other runtime versions are not a compatibility guarantee.

Trees cap at 250 components and 4,000 runtime nodes. Value snapshots cap depth, key count and string length, preserve cycle markers, and inspect descriptors instead of invoking application property getters. Reflection on framework proxies and Svelte's explicit development state API still runs in the page world. These are developer inspection aids, not trusted security evidence. Cross-origin frame and shadow-root content retain the limits described in [[Shaar_Inspector]].

## Accessibility

Roles, computed accessible names, ignored status and exposed properties come from Chromium's `Accessibility.getPartialAXTree`, matched to the selected DOM backend node. ARIA attributes come from the element. The panel checks missing names on interactive roles, missing image alt attributes, duplicate IDs, hidden focus targets and the existing computed text-contrast result.

Tab position is an explicit document estimate over up to 5,000 candidates. Shadow roots, nested frames, radio groups and browser focus rules can change actual sequential order. The loopback fixture verifies the common order using trusted renderer Tab input in the headless contract. This selected-element view is not a complete page accessibility audit.

## Assets

Images show rendered versus natural dimensions, engine-reported MIME type and exposed Resource Timing byte counts. Cached or restricted timing remains unavailable rather than receiving an invented transfer size. Downloads use Chromium's cached resource body in the correct frame/profile and a user-invoked native save panel; there is no separate URLSession request. Resource exports are bounded to 32 MiB. SVG copy preserves actual markup and rejects content above 256 KiB.

Rendered font names reuse the existing sampled font inventory. Loaded font files are listed separately from names, without guessing a file-to-family mapping; system fonts have no page resource. Asset MIME types and frame IDs are taken from the engine resource tree, not trusted from page-script payloads. `Page.enable` is required before reading cached resource content.

## Verification

`InspectorProbe` runs real React, Vue and Svelte development applications on `inspector.localhost`, checks live state changes and dev source metadata, verifies Chromium role/name results and warnings, and decodes downloaded PNG bytes to confirm original resolution. The test-only runtime bundle is pinned and hash-checked in `ThirdParty/InspectorFixtures`, with upstream licenses preserved. The headless contract additionally verifies cycle/getter handling and actual Tab order. Save dialogs are not opened by probes.

Opt-in public captures use React's public documentation for exposed component data, plus MDN and W3C documentation for accessibility and images/fonts. Native panels render offscreen with live page data. They establish layout and bounded renderer behavior, not physical hover timing or VoiceOver speech.

- React component data: [light](Assets/Shaar_Inspector_Details/react-light.png), [dark](Assets/Shaar_Inspector_Details/react-dark.png).
- MDN accessibility: [light](Assets/Shaar_Inspector_Details/mdn-a11y-light.png), [dark](Assets/Shaar_Inspector_Details/mdn-a11y-dark.png).
- MDN assets: [light](Assets/Shaar_Inspector_Details/mdn-assets-light.png), [dark](Assets/Shaar_Inspector_Details/mdn-assets-dark.png).
- W3C assets: [light](Assets/Shaar_Inspector_Details/wcag-assets-light.png), [dark](Assets/Shaar_Inspector_Details/wcag-assets-dark.png).

References: [React Fiber types](https://github.com/facebook/react/blob/main/packages/react-reconciler/src/ReactInternalTypes.js), [Vue component metadata](https://github.com/vuejs/core/blob/main/packages/runtime-core/src/component.ts), [Svelte DOM metadata](https://github.com/sveltejs/svelte/blob/main/packages/svelte/src/internal/client/dev/elements.js), [Svelte dev ancestry](https://github.com/sveltejs/svelte/blob/main/packages/svelte/src/internal/client/context.js), [CDP accessibility](https://chromedevtools.github.io/devtools-protocol/tot/Accessibility/).

Related: [[Shaar_Inspector]], [[Shaar_Inspector_CSS]], [[Verification_Harness]]. Issue: [#366, Phase C](https://github.com/arcusis/shaar/issues/366).
