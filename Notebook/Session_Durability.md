# Session durability

Merged in [PR #331](https://github.com/arcusis/shaar/pull/331). Both `SessionFile` and `WorkspaceFile` use `SnapshotFile` in BrowserCore. A save validates the model, creates an owner-only temporary file, writes and flushes it with `F_FULLFSYNC` (falling back to `fsync`), hard-links the previous primary into `.backup`, atomically renames the new primary and flushes the directory. The next save removes temporary files left by an interrupted writer.

Loading validates the primary before using it. If it is damaged and a valid backup exists, the primary moves to `.damaged` and the backup supplies the model; startup then saves the recovered workspace before engine restoration. With no valid backup, damaged bytes stay untouched and temporary windows cannot overwrite them. A missing primary can also load the backup. Invalid managed files never fall back to a stale legacy session.

`SnapshotSaveScheduler` serializes ordinary saves on a background queue without a delay; rapid Space switches coalesce for 250 ms. Tab URL/title, Favorite navigation, selection, profile/catalog edits, window focus, geometry and window lifecycle changes schedule saves. Launch, restoration and quit can write synchronously and drain pending work. A crash before a queued save completes can lose the latest change. A scheduled write runs at most once even if a flush races it, preserving the previous backup.

`SnapshotFileTests`, `SnapshotSaveSchedulerTests` and `BrowserWorkspaceStoreTests` cover round trips, fallback, malformed-data preservation, scheduling and retry. `bash scripts/test-engine.sh --session-recovery` interrupts the production writer with SIGKILL against an exact printed disposable PID and restores in a fresh process. That proves authored process-crash recovery; it does not simulate physical power loss or make Chromium's cookie writes synchronous. See [[Abrupt_Restart_Durability]].

Related: [[Managed_Workspace_Persistence]], [[Verification_Harness]].
