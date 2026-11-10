# 3D stacking view — offscreen evidence

The hidden `ShaarStackingViewVisualTests` fixture rendered the 3D view in an unshown window in Aqua and Dark Aqua. No browser window was opened for these captures, and no Chromium engine was built. Images are 980×640.

Before, the panel asks for a snapshot. After, a Z-index snapshot shows seven elements and four stacking contexts. `#modal` (z-index 10) is selected and sits above the page. `#behind` (z-index -1) is below that plane. `#faded` is a context because its opacity is below 1. `#card` is absolute with z-index auto, so it stays in the parent context and is not listed.

| Surface | Before | After |
| --- | --- | --- |
| Light | [before-light.png](before-light.png) | [after-light.png](after-light.png) |
| Dark | [before-dark.png](before-dark.png) | [after-dark.png](after-dark.png) |

Capture command: `SHAAR_STACKING_CAPTURE=1 shaar-heavy swift test -j 4 --filter ShaarStackingViewVisualTests`.

The shipping proof loads a loopback fixture and https://example.com in a hidden window: `python3 scripts/test-stacking-view-probe.py --app build/Shaar.app --receipt Evidence/issue-1486/stacking-probe.json`. On the fixture, choosing the modal slab selects that element in Elements. example.com captures its own stacking contexts the same way. A hidden window does not paint the canvas, so the pictures in this folder are the offscreen renders.
