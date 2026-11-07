# Sensors idle state — offscreen evidence

The hidden `ShaarDevToolsSensorsVisualTests` fixture rendered the Sensors section in an unshown window in Aqua and Dark Aqua. No browser window was opened for the captures, and no Chromium engine was built. Before images are 850×620. After images are 850×760 so the idle row fits.

| Surface | Before light | After light | Before dark | After dark |
| --- | --- | --- | --- | --- |
| Empty | [PNG](before-empty-light.png) | [PNG](after-empty-light.png) | [PNG](before-empty-dark.png) | [PNG](after-empty-dark.png) |
| San Francisco, New York, French | [PNG](before-sensors-light.png) | [PNG](after-sensors-light.png) | [PNG](before-sensors-dark.png) | [PNG](after-sensors-dark.png) |

Before, the panel sets location, timezone, and locale, and touch stays disabled. After, an Idle menu sits under touch. On shaar.20 it stays on System and says the next engine build is required. The populated capture shows Idle once that command is treated as available.

Idle override is command 70 and clear is command 71 in patch `0039-shaar-devtools-idle-override`. The same patch lets an empty `timezoneId` or `locale` through, which is how the panel returns to the system value. shaar.20 rejects both empty strings today.

A hidden probe against pinned shaar.20, using the engine-preview bundle so the run does not touch the login keychain, loaded a loopback page in a window that stayed hidden. Asia/Tokyo and `fr-FR` applied. An empty timezone left the page on Asia/Tokyo. An empty locale left `Intl` on `fr-FR`. Both empty calls, and `Emulation.clearIdleOverride`, came back as `DevTools request failed.` The receipt is [sensors-probe.json](sensors-probe.json).

Capture command: `SHAAR_DEVTOOLS_SENSORS_CAPTURE=1 nice -n 10 swift test -j 4 --filter ShaarDevToolsSensorsVisualTests`.

Probe command: `python3 scripts/test-sensors-override-probe.py --app "build/Shaar Engine Preview Debug.app" --receipt Evidence/issue-1313/sensors-probe.json`.
