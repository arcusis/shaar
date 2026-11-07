# Recorder — offscreen evidence

The hidden `ShaarDevToolsRecorderVisualTests` fixture rendered the Recorder section in an unshown window in Aqua and Dark Aqua. No browser window was opened for the captures, and no Chromium engine was built. Images are 850×620. The Record tab is selected. Replay and Export stay disabled until a step exists.

| Surface | Light | Dark |
| --- | --- | --- |
| No steps | [before-empty-light.png](before-empty-light.png) | [before-empty-dark.png](before-empty-dark.png) |
| Click and input | [after-recorder-light.png](after-recorder-light.png) | [after-recorder-dark.png](after-recorder-dark.png) |

A hidden probe against pinned shaar.20, using the engine-preview bundle so the run does not touch the login keychain, loaded a loopback page in a window that stayed hidden. It installed the recorder listener, replayed one click on `#shaar-flow-target`, and required both the page and the recorder buffer to see that click. The receipt is [recorder-probe.json](recorder-probe.json).

Capture command: `SHAAR_DEVTOOLS_RECORDER_CAPTURE=1 nice -n 10 swift test -j 4 --filter ShaarDevToolsRecorderVisualTests`.

Probe command: `python3 scripts/test-recorder-probe.py --app "build/Shaar Engine Preview Debug.app" --receipt Evidence/issue-1318/recorder-probe.json`.
