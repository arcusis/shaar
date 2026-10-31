# Abrupt restart durability

The opt-in abrupt-restart fixture checkpoints an authored session, validates its child process ownership and saved bytes, then terminates only that disposable process group. After restart, it compares the saved model and verifies restored native identities and Profile data. Missing, altered, malformed, foreign, or aliased checkpoint data fails the check; recovery does not repair the checkpoint.

```sh
bash scripts/test-engine.sh --abrupt-restart
bash scripts/test-engine.sh --abrupt-control
```

The strict mode tests process termination, not power loss or interruption during a session write. Chromium batches cookie-store writes on a timer or size threshold, so recently created cookies may not yet be durable at termination. The control mode adds an idle interval and is diagnostic only; it cannot establish strict crash-recovery acceptance. Neither mode verifies real Keychain behavior or external service accounts.

After the engine script creates `.venv`, runner checks can be executed with:

```sh
.venv/bin/python -m unittest discover -s Tests/EngineFixtureTests
```

Related: [[Managed_Workspace_Persistence]], [[Source_And_Native_Verification]].
