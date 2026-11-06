# Inspector source and agent context

The locked-element copy menu offers **Open source** and **Copy for agent**. Open source uses development component metadata from React, Vue, Svelte or Angular; locator plugin source attributes take precedence. For plain DOM it searches same-origin, bounded script source maps for one unique literal element ID in `sourcesContent`. Ambiguous matches and builds without source metadata show the location as unavailable. Editor choices are VS Code, Cursor, Zed, JetBrains, or **Show location**; the choice is stored locally. Only absolute local file paths are opened through editor URL schemes. Relative and non-file locations are shown in the dock.

Copy for agent reuses the selected element's private form-value scrubber and bounded HTML formatter. It copies a text-only Markdown block of at most 4 KiB with sanitized page URL, component chain and source, existing Playwright locator, role/name, dimensions, key styles and a small HTML excerpt. It never starts a screenshot or page diagnostics collection.

The headless renderer contract covers React and Vue source lookup, explicit source attributes and a unique plain-DOM source-map match. Native formatter tests cover bounds, privacy and editor URLs. The unordered offscreen copy-menu captures cover 320 and 420 point docks in light and dark. The previous menu is recorded in [[Shaar_Inspector_Redesign]].

| Width | Light | Dark |
| --- | --- | --- |
| 320 pt | [PNG](Assets/Shaar_Inspector_Source/copy-menu-320-light.png) | [PNG](Assets/Shaar_Inspector_Source/copy-menu-320-dark.png) |
| 420 pt | [PNG](Assets/Shaar_Inspector_Source/copy-menu-420-light.png) | [PNG](Assets/Shaar_Inspector_Source/copy-menu-420-dark.png) |

Related: [[Shaar_Inspector]], [[Shaar_Inspector_AI_Copy]], [[Shaar_Inspector_Details]], [[Shaar_Inspector_Redesign]]. Issue: [#1083](https://github.com/arcusis/shaar/issues/1083).
