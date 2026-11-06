# Developer tools polish — offscreen evidence

The hidden `DeveloperToolsPolishVisualTests` fixture rendered each SwiftUI surface in an unshown `NSWindow` in Aqua and Dark Aqua. No browser window was opened and no Chromium engine was built. Images are 1× captures. The fixture uses a local Next.js page, a selected Inspector element, a sample axe result, inactive CSS declarations, and a simulated local agent bridge.

| Surface | Before light | After light | Before dark | After dark |
| --- | --- | --- | --- | --- |
| Dev Mode toolbar indicator | [PNG](before-dev-mode-light.png) | [PNG](after-dev-mode-light.png) | [PNG](before-dev-mode-dark.png) | [PNG](after-dev-mode-dark.png) |
| Inspector source and copy actions | [PNG](before-source-actions-light.png) | [PNG](after-source-actions-light.png) | [PNG](before-source-actions-dark.png) | [PNG](after-source-actions-dark.png) |
| Accessibility audit, empty | [PNG](before-audit-empty-light.png) | [PNG](after-audit-empty-light.png) | [PNG](before-audit-empty-dark.png) | [PNG](after-audit-empty-dark.png) |
| Accessibility audit, results | [PNG](before-audit-results-light.png) | [PNG](after-audit-results-light.png) | [PNG](before-audit-results-dark.png) | [PNG](after-audit-results-dark.png) |
| Inactive CSS hints | [PNG](before-inactive-css-light.png) | [PNG](after-inactive-css-light.png) | [PNG](before-inactive-css-dark.png) | [PNG](after-inactive-css-dark.png) |
| Agent bridge, off | [PNG](before-agent-off-light.png) | [PNG](after-agent-off-light.png) | [PNG](before-agent-off-dark.png) | [PNG](after-agent-off-dark.png) |
| Agent bridge, connected | [PNG](before-agent-connected-light.png) | [PNG](after-agent-connected-light.png) | [PNG](before-agent-connected-dark.png) | [PNG](after-agent-connected-dark.png) |
| Agent connection banner | [PNG](before-agent-banner-light.png) | [PNG](after-agent-banner-light.png) | [PNG](before-agent-banner-dark.png) | [PNG](after-agent-banner-dark.png) |
| Agent bridge, loading | — | [PNG](after-agent-loading-light.png) | — | [PNG](after-agent-loading-dark.png) |
| Agent bridge, error | — | [PNG](after-agent-error-light.png) | — | [PNG](after-agent-error-dark.png) |

The Dev Mode action menu is a native macOS menu and cannot be ordered for a hidden screenshot. Its label and menu actions are covered by source and keyboard tests. The snapshots establish SwiftUI layout and theme behavior only; hosted CI and the existing hidden probes cover deeper integration.

Capture command: `SHAAR_DEVTOOLS_CAPTURE_PHASE=after nice -n 10 swift test -j 4 --filter DeveloperToolsPolishVisualTests`.
