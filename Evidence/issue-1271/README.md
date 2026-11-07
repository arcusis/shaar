# Box model editing — offscreen evidence

The hidden `ShaarBoxModelVisualTests` fixture rendered the Design-tab box diagram in an unshown window in Aqua and Dark Aqua. No browser window was opened and no Chromium engine was built. Images are 1× captures at the 320-point dock width.

| Surface | Before light | After light | Before dark | After dark |
| --- | --- | --- | --- | --- |
| Box model | [PNG](before-box-light.png) | [PNG](after-box-light.png) | [PNG](before-box-dark.png) | [PNG](after-box-dark.png) |

Before, every edge is a label. After, padding-top is an open field containing `10`. Enter applies the value through the same inline style edit as the Styles pane, so the Styles Undo button restores it. An empty field clears that override. Hovering a label still highlights that edge. The diagram beside Computed uses the same field once the element is locked.

Capture command: `SHAAR_BOX_CAPTURE=before nice -n 10 swift test -j 4 --filter ShaarBoxModelVisualTests`, then the same command with `SHAAR_BOX_CAPTURE=after`.
