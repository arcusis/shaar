# Inspector CSS and layout tools

The Inspector's **CSS** tab reads matched rules and computed values from the selected element through Chromium's CSS domain. The native panel groups layout, element overrides, matched declarations, computed properties and tools. Source badges show generated stylesheet lines. Inline sources use a `#style-N` block identifier and block-relative lines.

The DevTools bridge drops `CSS.styleSheetAdded` events, including stylesheet headers. Shaar first matches the exact selector and normalized declarations against accessible CSSOM rules, including imports and nested groups. It then tries matching `CSS.getStyleSheetText` against inline style text and loaded stylesheet resource bodies. Ambiguous or inaccessible sources show **Source unavailable**, with the stylesheet identifier in hover help; no URL is invented. CSSOM traversal stops at 12,000 rules. The resource fallback samples at most 32 external resources, 4 MiB per stylesheet and 8 MiB total, and stops starting further reads after five seconds. Source maps are not decoded. Rules are cascade candidates for the selected element; computed values show the final result. Inherited and pseudo-element rule chains are not presented as selected-element rules.

**Element overrides** applies a property/value to the locked element's inline style, with optional `!important`. Selecting a matched declaration fills the editor. Empty values remove an override. Chromium validates CSS values before applying them. Undo retains up to 50 edits and restores the exact prior inline attribute, including shorthand declarations and absence of the attribute. If the page changes that attribute afterward, undo refuses to overwrite those changes. Edits remain until reload; closing Inspector clears undo history.

**Copy CSS** exports a computed snapshot of layout, box edges, colors and typography. **Tailwind** exports those values as theme-independent arbitrary-property utilities; this is a snapshot, not a reconstruction of the page's authoring configuration. The computed property disclosure supports filtering and per-value copying.

Flex and grid containers expose native toggles backed by Chromium's `Overlay.setShowFlexOverlays` and `Overlay.setShowGridOverlays`. Grid overlays use the engine's actual tracks and labels rather than approximated child rectangles. Changing the inspected element or closing the dock clears its overlay.

Holding Option over another element draws distance guides in the page overlay. Separated rectangles show horizontal and vertical gaps; overlapping rectangles show leading-edge offsets. Coordinates include accessible frame offsets and scaling. This uses bounding rectangles, so rotated or nonrectangular shapes do not receive a shape-to-shape distance claim.

The header camera action captures the selected element as PNG at two pixels per CSS pixel and opens a save panel when the user invokes it. Inspector shading is hidden for capture and restored afterward. Capture is bounded to 16 megapixels at 2× and a 16,384-pixel maximum side. Verification calls the data capture directly and never opens a save panel or visible window.

## Verification

The loopback `InspectorProbe` exercises real matched-rule source resolution, computed spacing, live editing and exact undo, trusted Option pointer input, PNG pixel dimensions, grid/flex overlay protocol acceptance and engine-computed grid geometry. Initial and restart phases both run these checks. The headless renderer contract additionally checks invalid CSS rejection and protection against later page edits. Existing inspect-mode checks continue to run.

Opt-in public captures select real MDN and W3C headings and render the **CSS** tab offscreen in both appearances. Sources and values come from the pinned engine. Captures prove native layout and current renderer data; they do not establish a complete CSS debugger or physical interaction audit.

- MDN: [light](Assets/Shaar_Inspector_CSS/mdn-light.png), [dark](Assets/Shaar_Inspector_CSS/mdn-dark.png).
- W3C: [light](Assets/Shaar_Inspector_CSS/wcag-light.png), [dark](Assets/Shaar_Inspector_CSS/wcag-dark.png).

References: [CDP CSS](https://chromedevtools.github.io/devtools-protocol/tot/CSS/), [CDP Overlay](https://chromedevtools.github.io/devtools-protocol/tot/Overlay/), [CDP captureScreenshot](https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-captureScreenshot), [Tailwind arbitrary properties](https://tailwindcss.com/docs/adding-custom-styles#arbitrary-properties).

Related: [[Shaar_Inspector]], [[Engine_Interop_Boundary]], [[Verification_Harness]]. Issue: [#366, Phase B](https://github.com/arcusis/shaar/issues/366).
