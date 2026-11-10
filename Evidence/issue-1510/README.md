# HTTPS-only settings — offscreen evidence

The hidden `HttpsOnlySettingsVisualTests` fixture rendered Privacy & Security in an unshown window in Aqua and Dark Aqua. No browser window was opened and no Chromium engine was built. Images are 1× captures at 720×640 points.

| Surface | After light | After dark |
| --- | --- | --- |
| Privacy & Security | [PNG](after-privacy-light.png) | [PNG](after-privacy-dark.png) |

The previous privacy pane listed HTTPS-only browsing only under Private Windows, with the value Engine controlled. A regular profile had no switch. The pane now has Always use secure connections for the selected profile. The switch is on unless that profile has an explicit off value. Private windows stay engine controlled.

Capture command: `SHAAR_HTTPS_ONLY_CAPTURE=1 nice -n 10 swift test -j 4 --filter HttpsOnlySettingsVisualTests`.
