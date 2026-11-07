# Event listeners — offscreen evidence

The hidden `ShaarEventListenersTests` fixture rendered the Event Listeners pane in an unshown window in Aqua and Dark Aqua. No browser window was opened for the captures, and no Chromium engine was built. Images are 520×360.

A selected element lists its click listener and an ancestor keydown listener. The keydown row is capture and passive. Hiding ancestors leaves the click listener. Passive and Once are buttons, and each row can be removed.

| Surface | Light | Dark |
| --- | --- | --- |
| No selection | [before-empty-light.png](before-empty-light.png) | [before-empty-dark.png](before-empty-dark.png) |
| Click and ancestor keydown | [after-listeners-light.png](after-listeners-light.png) | [after-listeners-dark.png](after-listeners-dark.png) |
| Ancestors hidden | [after-ancestors-off-light.png](after-ancestors-off-light.png) | [after-ancestors-off-dark.png](after-ancestors-off-dark.png) |

Capture command: `SHAAR_EVENT_LISTENERS_CAPTURE=1 nice -n 10 swift test -j 4 --filter ShaarEventListeners`.

A hidden probe against pinned shaar.20, using the engine-preview bundle so the run does not touch the login keychain, loaded a loopback page in a window that stayed hidden. `DOM.getDocument` and `DOM.resolveNode` succeeded for `#shaar-listener`. `DOMDebugger.getEventListeners` and `Runtime.callFunctionOn` with an `arguments` array were both rejected. The bridge reports that rejection as `DevTools request failed.` The receipt is [event-listeners-probe.json](event-listeners-probe.json).

Probe command: `python3 scripts/test-event-listeners-probe.py --app "build/Shaar Engine Preview Debug.app" --receipt Evidence/issue-1272/event-listeners-probe.json`.

`DOMDebugger.getEventListeners` is not in the shaar.20 allowlist. Patch `0043-shaar-devtools-event-listeners.patch` adds inspector command 80 and allows a bounded `arguments` array on `Runtime.callFunctionOn`. `git apply --check` succeeds against the pinned shaar.20 tree. The pane uses a fixture until that engine build exists.
