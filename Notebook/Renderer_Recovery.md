# Renderer recovery

Renderer termination shows a native recovery panel while retaining the live tab, space, and profile. Reload page, the toolbar, and Command-R use the selected owning profile; stale controls cannot reload another tab or a replacement document. A committed replacement document clears the panel. Failed-page find state and pending consent are canceled. Background failures preserve the current selection and launcher. Failure metadata is transient; relaunch opens the saved page URL normally. Recovery can lose unsaved forms and JavaScript state. The strict abrupt-process probe described below currently fails for cookies that have not reached disk.

Renderer recovery checks intentionally terminate an authored localhost renderer through in-process CDP, with no debugging socket. The crash hook is restricted to disposable probe runs and dedicated loopback fixture paths. Checks verify real termination callbacks, retained tab identity/profile, reload into a fresh document with the same cookies/local storage, resumed Find, stale/foreign/background reload rejection, and preservation of unrelated live account documents and launcher state. A failed background tab is left for graceful browser restart to verify normal restoration from its saved URL. Native recovery light/dark layouts are captured offscreen. Unit checks cover consent cancellation, stopped/rejected reloads, and exclusion of failure state from session persistence. These checks do not establish recovery from browser-process crashes, physical memory pressure, every extension renderer, or actual native input.

Related: [[Abrupt_Restart_Durability]].

Pinned tabs also survive native WebContents destruction (#1013). The engine's
`WebContentsDestroyed` → `CleanupTab` path emits the same tab `closed` event as
an intentional close. The bridge and router forward it to `BrowserEngine`,
which previously called `BrowserStore.nativeTabClosed` without checking user
intent and consequently archived the pin and removed its shared catalog entry.
Renderer-gone itself, failed opens in reconciliation, and `NativeBrowserHost`
restore/attach do not archive tabs. The issue's saved snapshots establish the
archival, but do not identify the native event that triggered those sessions.

`BrowserStore` now requires an explicit tab-close request before archiving a
pin. Renderer failure or a replacement document clears pending close intent.
When an unsolicited close destroys the native tab, the engine drops its live
state and shows recovery while retaining the saved pin, selection, and profile.
It waits for Reload rather than repeatedly reopening during reconciliation.
Reload recreates missing native tabs from their saved URL; failed startup opens
can be retried the same way. Live crashed renderers still use native reload.

`PinnedTabRecoveryTests` covers unsolicited closes, explicit close/reopen,
renderer loss, startup-open failures (including a close callback during open),
disk persistence, and shared window pins using a fake runtime without windows.
These tests do not replay the original shaar.11/12 launch or prove native page
painting. Existing archived pins can be restored using [[Closed_Tab_Recovery]];
there is no blanket migration because older entries do not record close intent.
