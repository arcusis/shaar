# Inspector export and Inspect panel

Issue [#379](https://github.com/arcusis/shaar/issues/379) refines [[Shaar_Inspector_AI_Copy]] and the native [[Shaar_Inspector]]. The panel follows [Figma Dev Mode Inspect](https://mobbin.com/screens/fb73f09d-1f19-4257-8c65-855f85dc116e): quiet tabs, collapsible sections, List/Code modes, numbered code blocks and copy feedback. The [Webflow Style panel](https://mobbin.com/screens/6e523e1d-b437-47fd-b591-f1c44a6160d1) supplies the compact display/spacing structure; the issue specifies the MagicPath typography preview and fill-row details. Native semantic colors and existing Shaar surfaces remain the palette.

## Clipboard and image lifetime

Element export uses **one pasteboard item** with plain text, Markdown and PNG representations. Markdown includes `Screenshot: <absolute path>` so a local coding agent can open the attachment when its terminal accepts only text. PNGs live in `~/Library/Caches/Shaar/Inspector/`; new captures prune owned regular PNGs older than seven days. Files use private permissions. Copy image exports PNG alone; Copy with notes combines element context and notes without clearing them. The existing batch Notes copy still clears successfully copied notes with undo.

All image export paths retain the form-control masking, mutation checks and stale-selection guards described in [[Shaar_Inspector_AI_Copy]]. Cache files contain the masked screenshot. No upload is introduced.

## Context quality

Accessible names come from authored ARIA, alt, title or label metadata. Ordinary section text remains text content. Unknown metadata is omitted, dimensions use whole pixels, repeated nearby context is removed, and text truncation ends at word boundaries. Component lookup skips short or mangled names and continues toward readable ancestors; this remains a runtime naming heuristic.

CSS selectors prefer unique IDs, test attributes, authored ARIA/stable attributes, then short structural paths. Every candidate is checked with `querySelectorAll`; utility-class-only selectors are not generated. Markup keeps the selected opening tag and first-level child tags, collapses deeper content, shortens long URLs and preserves complete tags within its size budget. URL and form-value sanitization remain in force. Exported Markdown, CSS and DOM data remain English/data regardless of interface language.

## Panel ownership

Section collapse and List/Code choices belong to the tab's Inspector model, scoped by panel tab. Geometry belongs to each native panel instance; offscreen capture audits are supplied separately so a live dock and a capture cannot overwrite each other's anchors. At narrow widths the six tabs show icons with tooltips. Wider docks add labels. Ancestors remain individually clickable in a horizontal scroll view.

The spacing widget uses neutral rectangles, dim dashes for zero values and emphasized non-zero values. Hover requests highlight the matching page edge through the existing page-script bridge; Page mode and teardown clear that emphasis. Typography is hidden without rendered text. Color rows include swatch, value and opacity, and contrast reports independent AA/AAA results or a specific limitation.

## Verification boundary

Formatter snapshots and headless renderer contracts cover authored names, selector uniqueness, minified-name fallback, pruned markup and screenshot references. Native tests cover the single-item pasteboard, cache age/ownership, per-tab section preferences and dock/menu bounds. `InspectorAICopyProbe` verifies actual PNG files and pasteboard bytes, image-only and notes export, edge highlighting, and the Design/Code/Notes/Copy-menu matrix at 320 and 420 points in both appearances. All capture windows remain unordered. These checks establish programmatic behavior and offscreen rendering, not physical terminal/chat paste acceptance.

Related: [[Shaar_Inspector_CSS]], [[Shaar_Inspector_Details]], [[Shaar_Inspector_Page_Tools]], [[Engine_Interop_Boundary]], [[Verification_Harness]].

## Offscreen captures

The [capture receipt](Assets/Shaar_Inspector_Redesign/capture.json) pins the tested English source and both engine phases (837 initial checks, 839 after restart). The matrix covers 320/420-point docks in light and dark.

| Panel | 320 light | 320 dark | 420 light | 420 dark |
| --- | --- | --- | --- | --- |
| Design | [PNG](Assets/Shaar_Inspector_Redesign/design-320-light.png) | [PNG](Assets/Shaar_Inspector_Redesign/design-320-dark.png) | [PNG](Assets/Shaar_Inspector_Redesign/design-420-light.png) | [PNG](Assets/Shaar_Inspector_Redesign/design-420-dark.png) |
| Code | [PNG](Assets/Shaar_Inspector_Redesign/code-320-light.png) | [PNG](Assets/Shaar_Inspector_Redesign/code-320-dark.png) | [PNG](Assets/Shaar_Inspector_Redesign/code-420-light.png) | [PNG](Assets/Shaar_Inspector_Redesign/code-420-dark.png) |
| Notes | [PNG](Assets/Shaar_Inspector_Redesign/notes-320-light.png) | [PNG](Assets/Shaar_Inspector_Redesign/notes-320-dark.png) | [PNG](Assets/Shaar_Inspector_Redesign/notes-420-light.png) | [PNG](Assets/Shaar_Inspector_Redesign/notes-420-dark.png) |
| Copy Menu | [PNG](Assets/Shaar_Inspector_Redesign/copy-menu-320-light.png) | [PNG](Assets/Shaar_Inspector_Redesign/copy-menu-320-dark.png) | [PNG](Assets/Shaar_Inspector_Redesign/copy-menu-420-light.png) | [PNG](Assets/Shaar_Inspector_Redesign/copy-menu-420-dark.png) |

Hebrew presentation uses the Inspector catalog while export formats remain data. Section state uses stable English identifiers. Copy-menu geometry stays in physical LTR coordinates, with its content following the launch language; isolated English/Hebrew captures assert tabs and menus stay within both dock widths.

Hebrew captures use seeded native selections in isolated locale test children; English captures above use the live loopback engine fixture. Both stay offscreen.

| Hebrew panel | 320 light | 320 dark | 420 light | 420 dark |
| --- | --- | --- | --- | --- |
| Design | [PNG](Assets/Shaar_Inspector_Redesign/he-design-320-light.png) | [PNG](Assets/Shaar_Inspector_Redesign/he-design-320-dark.png) | [PNG](Assets/Shaar_Inspector_Redesign/he-design-420-light.png) | [PNG](Assets/Shaar_Inspector_Redesign/he-design-420-dark.png) |
| Code | [PNG](Assets/Shaar_Inspector_Redesign/he-code-320-light.png) | [PNG](Assets/Shaar_Inspector_Redesign/he-code-320-dark.png) | [PNG](Assets/Shaar_Inspector_Redesign/he-code-420-light.png) | [PNG](Assets/Shaar_Inspector_Redesign/he-code-420-dark.png) |
| Notes | [PNG](Assets/Shaar_Inspector_Redesign/he-notes-320-light.png) | [PNG](Assets/Shaar_Inspector_Redesign/he-notes-320-dark.png) | [PNG](Assets/Shaar_Inspector_Redesign/he-notes-420-light.png) | [PNG](Assets/Shaar_Inspector_Redesign/he-notes-420-dark.png) |
| Copy Menu | [PNG](Assets/Shaar_Inspector_Redesign/he-copy-menu-320-light.png) | [PNG](Assets/Shaar_Inspector_Redesign/he-copy-menu-320-dark.png) | [PNG](Assets/Shaar_Inspector_Redesign/he-copy-menu-420-light.png) | [PNG](Assets/Shaar_Inspector_Redesign/he-copy-menu-420-dark.png) |

## Fixed dock width and readable ancestry

The page card and Inspector content use explicit viewport bounds. Switching between Design and Code cannot increase dock width; long CSS stays inside the dock. Six tab hit areas retain visible gaps, with icons at narrow widths and labels at 420 points. Breadcrumb chips show tag/ID identity while preserving renderer IDs and original labels for navigation and exports. Initial scroll targets keep the selected chip visible.

Offscreen width-stress captures compare production #376 with the redesign at 320/420 points in light/dark using the same seeded long-CSS selection. Native engine verification checks that all six Inspector tabs preserve the Chromium page viewport. Copy for AI and parent/child navigation handlers remain unchanged by this layout correction.

The [width comparison receipt](Assets/Shaar_Inspector_Redesign/Width_Regressions/capture.json) identifies baseline and revised source, shared fixture, dimensions and image hashes.

| Panel | Width | Appearance | Before (#376) | After |
| --- | --- | --- | --- | --- |
| Design | 320 pt | Light | [PNG](Assets/Shaar_Inspector_Redesign/Width_Regressions/before-design-320-light.png) | [PNG](Assets/Shaar_Inspector_Redesign/Width_Regressions/after-design-320-light.png) |
| Design | 320 pt | Dark | [PNG](Assets/Shaar_Inspector_Redesign/Width_Regressions/before-design-320-dark.png) | [PNG](Assets/Shaar_Inspector_Redesign/Width_Regressions/after-design-320-dark.png) |
| Design | 420 pt | Light | [PNG](Assets/Shaar_Inspector_Redesign/Width_Regressions/before-design-420-light.png) | [PNG](Assets/Shaar_Inspector_Redesign/Width_Regressions/after-design-420-light.png) |
| Design | 420 pt | Dark | [PNG](Assets/Shaar_Inspector_Redesign/Width_Regressions/before-design-420-dark.png) | [PNG](Assets/Shaar_Inspector_Redesign/Width_Regressions/after-design-420-dark.png) |
| Code | 320 pt | Light | [PNG](Assets/Shaar_Inspector_Redesign/Width_Regressions/before-code-320-light.png) | [PNG](Assets/Shaar_Inspector_Redesign/Width_Regressions/after-code-320-light.png) |
| Code | 320 pt | Dark | [PNG](Assets/Shaar_Inspector_Redesign/Width_Regressions/before-code-320-dark.png) | [PNG](Assets/Shaar_Inspector_Redesign/Width_Regressions/after-code-320-dark.png) |
| Code | 420 pt | Light | [PNG](Assets/Shaar_Inspector_Redesign/Width_Regressions/before-code-420-light.png) | [PNG](Assets/Shaar_Inspector_Redesign/Width_Regressions/after-code-420-light.png) |
| Code | 420 pt | Dark | [PNG](Assets/Shaar_Inspector_Redesign/Width_Regressions/before-code-420-dark.png) | [PNG](Assets/Shaar_Inspector_Redesign/Width_Regressions/after-code-420-dark.png) |
