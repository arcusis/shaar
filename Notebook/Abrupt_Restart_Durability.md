# Abrupt restart durability

An opt-in abrupt-process test waits for an authored-fixture checkpoint, verifies its child PID/process-group ownership and saved session bytes, then sends SIGKILL to that disposable group. It confirms group termination through read-only process inventory before relaunch. Startup compares the complete saved model before loading profiles, then verifies live native identities and profile/account data. Missing, changed, malformed, foreign, or aliased checkpoint data fails the test; the checkpoint never repairs the session.

```sh
bash scripts/test-engine.sh --abrupt-restart
bash scripts/test-engine.sh --abrupt-control
```

Earlier strict runs returned nonzero: session JSON, Spaces, tabs, folders, ordering, and closed entries restored, but newly created account cookies were missing while localStorage survived. Abrupt mode has not been rerun at the current native-host checkpoint; added fixture work changes the elapsed time before termination, so no current strict result or stronger durability is claimed. The pinned [Chromium cookie store](https://github.com/chromium/chromium/blob/155.0.8059.84/net/extras/sqlite/sqlite_persistent_cookie_store.cc) batches pending cookie operations on a 30-second timer or a size threshold. Those failing fixtures terminated within that window. The separate control adds a 35-second idle interval before SIGKILL; its receipt is explicitly marked `controlOnly`, and it cannot establish strict crash-recovery acceptance. `abrupt-recovery-summary.json` derives `strictAcceptancePassed` from the requested mode, fault receipt, and restart result while preserving both raw reports. Neither test exercises power loss, termination during an incomplete session write, real keychain behavior, or company accounts. Whether to accept Chromium's commit window or require stronger durability is a pending product decision.

After the engine script creates `.venv`, `.venv/bin/python -m unittest discover -s Tests/EngineFixtureTests` runs the parent runner's checkpoint, PID/group, cleanup, and control-label rejection checks.

Related: [[Managed_Workspace_Persistence]].
