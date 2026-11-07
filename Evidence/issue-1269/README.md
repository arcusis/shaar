# Styles rule editing — offscreen evidence

The hidden `ShaarStylesRuleVisualTests` fixture rendered the Inspector Styles tab in an unshown window in Aqua and Dark Aqua. No browser window was opened and no Chromium engine was built. Images are 1× captures at the 320-point dock width.

| Surface | Before light | After light | Before dark | After dark |
| --- | --- | --- | --- | --- |
| Matched rules | [PNG](before-styles-light.png) | [PNG](after-styles-light.png) | [PNG](before-styles-dark.png) | [PNG](after-styles-dark.png) |

Before, a declaration click only filled the element override form. After, an editable rule has a checkbox per declaration, struck-through disabled text, Add property, and New rule. Inherited and pseudo-element rules are labeled. User-agent rules stay read-only.

Capture command: `SHAAR_STYLES_CAPTURE=before nice -n 10 swift test -j 4 --filter ShaarStylesRuleVisualTests`, then the same command with `SHAAR_STYLES_CAPTURE=after`.
