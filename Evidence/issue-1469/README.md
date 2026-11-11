# Issue 1469 evidence

The before and after Site Controls captures use the same offscreen fixture in light and dark appearance. The label changed from “Shaar DevTools” to “Developer Tools.”

The Console, Network, Application, Sources, Performance, Memory, and Coverage captures show the retired panels before deletion. `after-legacy-shell-issues.png` records the intermediate navigation after those groups were removed and before the final shell retirement.

`f12-chromium-dock.png` and `option-command-i-chromium-dock.png` are the full offscreen browser-host captures after the final retirement. The hidden Chromium DevTools route smoke passed both shortcuts; all windows stayed hidden and no new crash reports appeared. The Inspector idle smoke also passed with `inspectorOpen: true`, all windows hidden, and no new crash reports. `build/Shaar.app` and the separate verification harness were built with the pinned engine.

Shaar Inspector remains available in the browser page layout. Chromium DevTools opens from F12, Option-Command-I, and the Developer Tools menu command.
