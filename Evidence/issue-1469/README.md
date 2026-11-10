# Issue 1469 evidence

The before and after Site Controls captures use the same offscreen fixture in light and dark appearance. The label changed from “Shaar DevTools” to “Developer Tools.”

The `before-site-controls-*` images were rendered with the production label from `origin/production`; the `after-site-controls-*` images were rendered from the follow-up source. The offscreen render test passed for both versions.

The hidden route probe also passed F12, Option-Command-I, F12 closing the legacy shell before opening Chromium DevTools, and the legacy-shell default route. All windows remained hidden and the probe found no new crash reports.
