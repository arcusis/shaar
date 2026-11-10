# Managed workspace persistence

The native host uses a managed workspace format and writer. They share Space/profile/folder metadata and original pin definitions, while each window retains distinct tab IDs, current navigation, selection, folder collapse, and closed-tab recovery. New windows copy no ordinary pages; shared pins receive separate local identities and load only when selected in the managed engine clients. Removing a shared pin preserves another window's existing page as an ordinary tab. Shared metadata changes retain existing native documents. This follows Arc's [window-local unpinned/shared-pin model](https://start.arc.net/release-notes), but does not establish complete Arc feature parity. Normal startup holds an OS workspace lock before loading models or profiles. Confirmed ordinary closure removes that window record; engine quit retains open records for restoration. Bounds and focused-window identity persist, and offscreen bounds clamp to current screens. Shared-Space deletion explains its cross-window impact. Real focus/input and cancellation dialogs, and primary/last-engine-window macOS reopen policy remain unverified.

Normal engine-backed sessions live in `workspace.json` under the user-level application support directory. The current version-2 workspace includes a shared catalog with Profile Favorites, validated per-window schema-v4 snapshots, optional geometry, and focused-window identity. Saved data includes profile/Space/tab IDs, URLs, titles, pins, Favorites, selection, folder hierarchy/membership/collapse state, and window-local closed-tab recovery. Version-1 workspaces migrate on load. Engine data remains in `Chromium/Profile <profile UUID>` below the same support directory. Developer ID builds use the OS keychain. Ad-hoc agent bundles may use the mock keychain, as described in [[Build_And_Run]]. Disposable tests use the mock keychain as well. No existing Chrome or Arc profile is imported.

When no workspace exists, `WorkspaceFile` reads legacy `session.json` (v1/v2/v3/v4) without rewriting it or changing identities. Native startup saves the managed snapshot before restoring pages.

Every persisted model change schedules a save. Ordinary saves run on a background queue immediately; Space switches coalesce for 250 ms. Launch, native restoration and quit can write synchronously and drain pending work. Flush ordering, backup recovery and the interval in which a crash can lose a queued change are described in [[Session_Durability]].

Quit intent is shared by the native bridge, event router and managed host. A host
Quit or native `engine.quitRequested`/`engine.willShutDown` notification checkpoints
the workspace before teardown. Tab removal and navigation/selection updates are
ignored during that teardown, and window closure retains its saved record even
when an individual native callback lacks the quitting flag. Cancellation clears
the guard so later explicit user closes still update the session.

The November 6 follow-up reproduced `windows: []` with the actual hidden host and
file writer when teardown delivered a window-close callback without that flag.
It also reproduced dropped user-close callbacks after a canceled Quit. The
ordinary Quit-menu native probe on shaar.13 preserved its window before the fix;
this does not establish which exit path produced David's reported empty file.
The separate Preview verification helper did explicitly close all normal windows
before requesting Quit, thereby deleting their records; it now uses host Quit.
`WorkspaceQuitPersistenceTests` checks two windows with ordinary tabs and pins,
late teardown navigation, native/host Quit, cancellation and disk reload.
[[Quit_Exit_Verification]] now checks saved sessions as well as process exit.

A workspace file that fails to decode or validate is moved to `workspace.json.damaged` and the backup is restored. Damaged data never falls back to a stale legacy session: when no valid backup exists, both files remain preserved and temporary windows report that changes will not be saved, so an empty session never overwrites them. Valid unsaved state survives IO failure for retry. A mode-0600 `workspace.lock` is held with an exclusive OS lock until engine shutdown, preventing another app process from writing the same workspace; the lock file is retained after release. The UI-only SwiftUI preview uses in-memory sample data and does not modify the workspace or legacy source.

Related: [[Session_Durability]], [[Abrupt_Restart_Durability]], [[Managed_Host_Verification]].
