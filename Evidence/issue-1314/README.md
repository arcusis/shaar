# Rendering drawer — offscreen evidence

The hidden `ShaarRenderingVisualTests` fixture rendered the Rendering section in an unshown window in Aqua and Dark Aqua. No browser window was opened and no Chromium engine was built. Images are 1× captures at 1040×520 points.

| Surface | Before light | After light | Before dark | After dark |
| --- | --- | --- | --- | --- |
| Rendering | [PNG](before-rendering-light.png) | [PNG](after-rendering-light.png) | [PNG](before-rendering-dark.png) | [PNG](after-rendering-dark.png) |

Before, color scheme, reduced motion, and CSS media are cleared, and the overlay toggles are disabled. After, the section asks for a dark color scheme, reduced motion, and print media, and paint flashing is on. Closing DevTools sends an empty media value and empty feature values.

Paint flashing, layout-shift regions, and the FPS meter are commands 66–68 in patch `0036-shaar-devtools-rendering-overlay`. Command 65 is touch emulation. The current shaar.20 engine does not allow the overlay commands yet, so the live toggles stay off until that build. Color scheme, reduced motion, and print already go through `Emulation.setEmulatedMedia`.

A hidden probe against pinned shaar.20, using the engine-preview bundle so the run does not touch the login keychain, loaded a loopback page in a window that stayed hidden. Dark color scheme, reduced motion, and print media all matched. Clearing the override restored screen media and no reduced motion. The system color scheme on that run stayed dark. `Overlay.setShowPaintRects` came back as `DevTools request failed.`, which is how shaar.20 reports a command past 64. The receipt is [rendering-probe.json](rendering-probe.json).

Capture command: `SHAAR_RENDERING_CAPTURE=before nice -n 10 swift test -j 4 --filter ShaarRenderingVisualTests`, then the same command with `SHAAR_RENDERING_CAPTURE=after`.

Probe command: `python3 scripts/test-rendering-media-probe.py --app "build/Shaar Engine Preview Debug.app" --receipt Evidence/issue-1314/rendering-probe.json`.
