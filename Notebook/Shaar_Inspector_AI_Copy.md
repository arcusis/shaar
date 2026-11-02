# Inspector context and page notes

**Copy for AI** and Shift-Command-C copy the locked element as Markdown in the first pasteboard item and its real 2× PNG in a second item. The first item supports plain text and `net.daringfireball.markdown`. Copy URL moves to Option-Shift-Command-C to keep the shortcuts distinct. Inspector context is collected from the existing selected element, selectors, component metadata and CSS collectors; no second picker or network upload is introduced.

The default message starts with “Attached browser context from” and includes the sanitized page URL, tag, accessible name/role, selector, known component/source information, dimensions, visible text, nearby context, non-default key styles, HTML, ancestry and full DOM path. Same-origin frame paths remain explicit. Detailed mode adds bounds/classes, full computed styles, matched CSS and sources, collected console/HTTP errors and technology markers. Diagnostics that were not enabled remain unavailable; copying does not silently start page recording. Notes capture their CSS snapshot when added so the Detailed switch can also apply after navigation.

## Privacy and image capture

Copied URLs lose credentials, query strings and fragments, including URLs inside diagnostics and feedback. DOM extraction omits input, textarea, select/option, editable, script and template content. Form-control selections cannot be copied. HTML is rendered by one pure formatter from a bounded tree and attribute allowlist, never raw `outerHTML`; text is limited to about 300 characters and HTML to 2 KiB. Current form values are also scrubbed from collected text. Markdown code fences adapt to embedded backticks.

Element images temporarily hide form controls and cover them with opaque masks. Opaque frame/plugin surfaces and custom-element hosts are covered as well. Original inline visibility is restored only while the copy operation still owns the applied value; Inspector teardown also cleans up its masks. Inserted controls or lost visibility protection invalidate the image before export. Navigation/selection/close guards prevent stale results from replacing the clipboard. A failed or refused copy leaves the clipboard unchanged. The engine's page-world instrumentation can be modified by a page, as described in [[Shaar_Inspector]]; the export is developer context, not a security audit.

## Notes and undo

Notes belong to the tab's Inspector model and stay in memory across page navigation and Inspector close/reopen. Each retains the selected context, an intent (Change, Question or Important), and feedback. Closing the tab retires its model. Notes are not written to preferences or uploaded.

Copy all for AI emits numbered Design Feedback sections grouped by sanitized page URL; multiple pages get a Design Feedback across pages heading. A successful batch copy clears the notes and exposes Undo clear. Undo preserves newer notes; if the 50-note limit is full, remaining cleared notes stay available until room is made. Deletion targets individual note IDs. Batch export is Markdown; element copy supplies the PNG attachment.

## Verification

`InspectorAIFormatterTests` contains checked-in snapshots for an element, Detailed on/off, two-page notes and sanitization, plus text/HTML limits and code-fence safety. Native tests cover per-tab ownership, navigation/close retention, copy-clear/undo, note limits, two-item clipboard representations, corrupt-image rejection and offscreen light/dark rendering. Renderer contracts execute the exact script with real React/Vue/Svelte metadata and check field omission and temporary mask restoration.

`InspectorAICopyProbe`, called from `InspectorProbe`, exercises real element copy, note grouping/undo/delete and detailed diagnostics on loopback pages in both fixture phases. It uses a uniquely named pasteboard instead of the system clipboard, decodes the PNG and checks raw mask channels (avoiding AppKit color-profile conversions). Both appearances remain unordered and offscreen. The normal fixture deadline includes the added copy/notes work; private-window, Quit and recovery deadlines/repetitions are unchanged.

Offscreen fixture captures: [element, light](Assets/Shaar_Inspector_AI_Copy/element-light.png) / [dark](Assets/Shaar_Inspector_AI_Copy/element-dark.png), [notes, light](Assets/Shaar_Inspector_AI_Copy/notes-light.png) / [dark](Assets/Shaar_Inspector_AI_Copy/notes-dark.png), and [Detailed notes, light](Assets/Shaar_Inspector_AI_Copy/detailed-light.png) / [dark](Assets/Shaar_Inspector_AI_Copy/detailed-dark.png). The [masked element PNG](Assets/Shaar_Inspector_AI_Copy/private.png) and [capture receipt](Assets/Shaar_Inspector_AI_Copy/capture.json) record the actual attachment and isolated pasteboard checks. These establish rendering and programmatic copy behavior; they do not establish physical keyboard or hover acceptance.

Related: [[Shaar_Inspector]], [[Shaar_Inspector_CSS]], [[Shaar_Inspector_Details]], [[Shaar_Inspector_Page_Tools]], [[Keyboard_Commands]], [[Verification_Harness]]. Issue: [#373](https://github.com/arcusis/shaar/issues/373).

Copy for AI and Notes interface strings use the Inspector String Catalog, with the command title also translated in Shell and Settings. Feedback intents retain their English protocol values in Markdown exports. Isolated English/Hebrew offscreen captures include the Notes panel and assert translated copy/notes labels; selectors, URLs and page-owned text remain data.
