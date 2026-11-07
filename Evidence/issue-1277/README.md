# Force pseudo-state — offscreen evidence

The hidden `ShaarPseudoForceVisualTests` fixture rendered the Styles force-state control in an unshown window in Aqua and Dark Aqua. No browser window was opened and no Chromium engine was built. Images are 1× captures at the 320-point dock width.

| Surface | Before light | After light | Before dark | After dark |
| --- | --- | --- | --- | --- |
| Force state | [PNG](before-force-light.png) | [PNG](after-force-light.png) | [PNG](before-force-dark.png) | [PNG](after-force-dark.png) |

Before, `:hover`, `:active`, `:focus`, `:focus-visible`, and `:focus-within` are idle. After, `:hover` is selected. The same control accepts any combination of those five states. Clearing the selection or closing DevTools sends an empty `CSS.forcePseudoState` list for the node that was forced. A fixture matched-rule list contains `button:hover` only while hover is on.

`CSS.forcePseudoState` is command 64 in patch `0034-shaar-devtools-force-pseudo-state`. The current shaar.20 engine does not allow that command yet.

Capture command: `SHAAR_PSEUDO_CAPTURE=before nice -n 10 swift test -j 4 --filter ShaarPseudoForceVisualTests`, then the same command with `SHAAR_PSEUDO_CAPTURE=after`.
