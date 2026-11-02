# Abrupt restart durability

The opt-in abrupt-restart fixture checkpoints an authored session, validates its child process ownership and saved bytes, then terminates only that disposable process group. After restart, it compares the saved model and verifies restored native identities and Profile data. Missing, altered, malformed, foreign, or aliased checkpoint data fails the check; recovery does not repair the checkpoint.

```sh
bash scripts/test-engine.sh --abrupt-restart
bash scripts/test-engine.sh --abrupt-control
```

The strict mode tests process termination, not power loss or interruption during a session write. Chromium batches cookie-store writes on a timer or size threshold, so recently created cookies may not yet be durable at termination. The control mode adds an idle interval and is diagnostic only; it cannot establish strict crash-recovery acceptance. Neither mode verifies real Keychain behavior or external service accounts.

The session-recovery fixture covers interruption during session writes. It builds a managed workspace through the production writer (Spaces, pinned and Today tabs, a favorite, a folder, a native navigation, selection and a second window), waits until background saves reach the file without an explicit flush, records the saved snapshot, then keeps saving window geometry until the runner sends SIGKILL to the exact child PID after a random delay. A fresh process must find a complete primary file, restore it without a storage notice, match the recorded snapshot (the geometry being written at the kill may hold either written value), reopen the navigated tab in the engine and remove the killed writer's temporary files.

```sh
bash scripts/test-engine.sh --session-recovery
```

It does not simulate power loss; `F_FULLFSYNC` ordering and backup fallback are covered by `SnapshotFileTests`.

[PR #331](https://github.com/arcusis/shaar/pull/331) reports the strict `--abrupt-restart` run failing at `restart restores Alpha Profile Favorite cookie` on its baseline and branch. Its summary also tries to read an `initial.json` that the killed initial phase never writes. That mode is not in CI. The distinct `--session-recovery` mode is in CI and verifies the managed JSON writer, not Chromium cookie-flush durability. See [[Session_Durability]].

After the engine script creates `.venv`, runner checks can be executed with:

```sh
.venv/bin/python -m unittest discover -s Tests/EngineFixtureTests
```

Related: [[Managed_Workspace_Persistence]], [[Source_And_Native_Verification]].
