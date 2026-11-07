# Computed winner trace — offscreen evidence

The hidden `ShaarComputedTraceVisualTests` fixture rendered the Inspector Styles tab in an unshown window in Aqua and Dark Aqua. No browser window was opened and no Chromium engine was built. Images are 1× captures at the 320-point dock width.

| Surface | Before light | After light | Before dark | After dark |
| --- | --- | --- | --- | --- |
| Computed | [PNG](before-computed-light.png) | [PNG](after-computed-light.png) | [PNG](before-computed-dark.png) | [PNG](after-computed-dark.png) |

Before, Computed was an alphabetical list of final values. After, the box model sits in that section, and each property names the selector and source of the declaration that won. In the fixture, `color` is `rgb(0, 0, 255)` from `button` in `style-2` (`blue !important`), not from the more specific `#save { color: red }`. `padding-top` points at the `padding` shorthand. `display` has no authored rule, so it has no source.

Capture command: `SHAAR_COMPUTED_CAPTURE=before nice -n 10 swift test -j 4 --filter ShaarComputedTraceVisualTests`, then the same command with `SHAAR_COMPUTED_CAPTURE=after`.
