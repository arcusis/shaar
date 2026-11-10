# Issue 1469 evidence

The before and after Site Controls captures use the same offscreen fixture in light and dark appearance. The label changed from “Shaar DevTools” to “Developer Tools.”

The `before-site-controls-*` images were rendered with the production label from `origin/production`; the `after-site-controls-*` images were rendered from the follow-up source. The offscreen render test passed for both versions.

The Console and Network screenshots show the retired legacy panels before deletion. `after-legacy-shell-issues.png` shows the remaining shell navigation without those panels; the Shaar Inspector remains in the page layout.

The hidden route probe passed F12 and Option-Command-I opening Chromium DevTools, F12 closing the legacy shell, and the legacy-shell default route. All windows remained hidden and the probe found no new crash reports.
