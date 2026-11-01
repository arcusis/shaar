# Quit exit verification

Merged in [PR #332](https://github.com/arcusis/shaar/pull/332), issue #321.

Quit must end the browser process and every Chromium helper. Two engine behaviors could leave a windowless process running:

- Chromium background mode. Extensions with the `background` permission may keep Chromium alive after its windows close. Chromium 155 has no switch for it, so the runtime sets `background_mode.enabled` to false in the profile directory's `Local State` before every launch. An unreadable `Local State` is left for Chromium to recover.
- A lost event-loop stop. After every browser closes, Chromium posts `NSApplicationWillTerminateNotification`, releases its keep-alives and stops the AppKit loop when idle. That stop can be lost, leaving the process idle in `-[NSApplication run]` with an empty keep-alive registry. `ARCEngineShutdownGuard` repeats the stop five seconds after that notification and exits with `EX_SOFTWARE` if Chromium has not returned from its main function within 30 seconds.

```sh
bash scripts/test-engine.sh --quit-exit
```

The probe loads the MV3 fixture into two disposable profiles, restores hidden host windows, then sends the host's Quit menu action. The runner times the browser exit (15 s bound) and the absence of its process group (10 s bound) from the probe's checkpoint and writes `<phase>-quit-exit.json`. Reports record whether the shutdown guard had to stop the loop; `<phase>-quit-keepalive.log` samples Chromium's keep-alive registry until the loop ends.

The bridge publishes confirmed window closure synchronously, before the engine loop can return. Native teardown remains queued, retaining native state until the close callback unwinds. Previously the host notification was inside that queue too: a fast clean exit could leave a host context registered at the probe's post-loop audit. [[Private_Fixture_Readiness]] documents the prerequisite correction and repeated hosted verification boundary.

Known engine crash: quitting while a tab navigation is pending crashes the pinned engine during teardown in about five of six runs (SIGSEGV on freed memory). The committing navigation has a non-network response and reaches `ReadyToCommitNavigation` observers after its window is gone; stopping loading tabs before Quit does not prevent it. The probe therefore quits with no navigation pending. The fix needs the engine sources.

The original PR reports six successful probe runs after the fix, including observed guard recovery. `BackgroundModeLocalStateTests` and `QuitExitRunnerTests` cover preference preservation and runner exit accounting. Identifier isolation in [[Verification_Harness]] and JSON persistence in [[Session_Durability]] do not fix the pending-navigation crash. Fixture results do not establish external extension compatibility or physical menu/keyboard behavior.

Related: [[Verification_Harness]], [[Session_Durability]], [[Engine_Source_Build]], [[Managed_Host_Verification]], [[Source_And_Native_Verification]].
