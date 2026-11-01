# Shaar Inspector

Option-Command-C, View → Inspect Element, or the site control center's **Inspect Element** action opens a native Inspector dock beside the selected page. Chromium's **Developer Tools** action and Option-Command-I remain available alongside it. Narrow cards place Inspector below the page.

## Element inspection

Hover previews the deepest element with margin, border, padding and content shading, a blue outline, and a tag/class size badge. Clicking locks selection without activating the page. Up selects the parent, Down the first visible child, and Left/Right visible siblings. The breadcrumb selects ancestors; its overflow menu retains earlier ancestors. Escape or Close removes the overlay and dock. Same-origin frames retain their frame chain in copied locators.

The header shows an exposed component name when available, tag, dimensions, and copy actions for CSS, Playwright, XPath and JavaScript. CSS chooses the shortest unique candidate from bounded tag, ID, attribute, class and ancestor candidates. Playwright prefers unique test IDs, confidently resolved roles/names, then text; uncertain cases use a unique CSS/XPath locator. This is not a complete accessible-name implementation. Shadow-root contents and cross-origin frame contents are outside Phase A; their host/frame element remains selectable.

The panel shows computed box edges and content size, computed typography, and Chromium's `CSS.getPlatformFontsForNode` rendered font names. The page font list queries actual rendered fonts for sampled text styles in accessible documents, including same-origin frames. Sampling groups by font style and broad script, caps at 160 groups, and refreshes every 15 seconds while inspection is active. It is not an exhaustive glyph/font inventory. Selection details refresh on change and at two-second intervals for font data.

Colors support HEX, RGB and OKLCH, preserving alpha in calculations. WCAG 2.2 contrast composites solid backgrounds and text alpha, uses the large-text thresholds where appropriate, and displays AA/AAA or Fail. Images, gradients, filters, blending, opacity and wide-gamut colors show an explicit contrast limitation instead of an invented score. Wide-gamut swatches are sRGB approximations. Ratios describe the selected element's computed text color and background, not a page-wide accessibility audit.

## Native and engine boundaries

`InspectorPage` allocates page-card space to the native SwiftUI panel; no separate tools window opens. Models belong to an exact tab, profile and native window, revalidate ownership before and after calls, reset on document changes, and close on tab/window teardown. Selection payloads have size, shape and finite-value bounds. Remote objects use unique groups released after each query.

The pinned ArdiaCore Chromium 155 bridge drops DevTools events. Inspector polls a page script rather than subscribing to events. The bridge also detaches idle DevTools clients, invalidating DOM/CSS IDs: overlapping bounded 30-second Runtime promises retain the inspection session; closing stops renewal. No debugging port opens. Idle inspection ends completely when the dock closes. The script runs in the page's world; hostile pages can modify it, so these results are inspection aids, not trusted security evidence.

## Verification and captures

`InspectorProbe` runs in both phases of `bash scripts/test-engine.sh` on `inspector.localhost`. It verifies trusted pointer hover/click, nonactivation while locking, arrow navigation, breadcrumb selection, box/style/rendered-font values, alpha contrast, complex-background limits, same-origin frames, Escape cleanup, native dock allocation and unchanged desktop focus. Probe windows remain unordered and offscreen.

`Tests/InspectorContractTests` runs the exact embedded page script in headless Playwright, including locator resolution and iframe navigation cleanup. CI uploads a source-hashed contract receipt. Run with `pnpm --dir Tests/InspectorContractTests test` after installing its pinned dependencies and Chromium headless shell. `InspectorColorTests` checks independent WCAG reference values and color conversion. Native unit coverage also validates selection acceptance, malformed-packet rejection, navigation/close retirement, JavaScript syntax, failure receipts, and unordered panel rendering across appearances and color formats. These transport-free tests complement the real-engine probes; they do not claim renderer execution. The staged CI aggregate requires the headless renderer contract job alongside the production gates.

`SHAAR_INSPECTOR_PUBLIC_CAPTURE=1 bash scripts/test-engine.sh` additionally visits MDN and W3C public documentation in disposable offscreen tabs, selects their headings through trusted renderer input, and captures the live panel in both appearances. Public capture is optional and excluded from deterministic CI. Panel captures prove native layout with real renderer data; they do not prove physical hover timing or VoiceOver speech.

- MDN: [light](Assets/Shaar_Inspector/mdn-light.png), [dark](Assets/Shaar_Inspector/mdn-dark.png), [page](Assets/Shaar_Inspector/mdn-page.png), [selection](Assets/Shaar_Inspector/mdn.json).
- W3C: [light](Assets/Shaar_Inspector/wcag-light.png), [dark](Assets/Shaar_Inspector/wcag-dark.png), [page](Assets/Shaar_Inspector/wcag-page.png), [selection](Assets/Shaar_Inspector/wcag.json).

Design references: [Figma Inspect](https://mobbin.com/screens/fb73f09d-1f19-4257-8c65-855f85dc116e), [Webflow style rail](https://mobbin.com/screens/7a26c826-99d9-4519-b2af-57e04a8b3a84), [Figma inspection guide](https://help.figma.com/hc/en-us/articles/22012921621015-Guide-to-inspecting). Technical references: [CDP CSS](https://chromedevtools.github.io/devtools-protocol/tot/CSS/), [CDP DOM](https://chromedevtools.github.io/devtools-protocol/tot/DOM/), [WCAG contrast](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum), [CSS Color 4 conversions](https://www.w3.org/TR/css-color-4/#color-conversion-code).

Related: [[Site_Control_Center]], [[Engine_Interop_Boundary]], [[Verification_Harness]]. Issue: [#366, Phase A](https://github.com/arcusis/shaar/issues/366).
