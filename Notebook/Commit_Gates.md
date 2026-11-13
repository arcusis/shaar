# Commit and push gates

Design for [#335](https://github.com/arcusis/shaar/issues/335), recorded before implementation. Reuse [[CI_Pipeline]] fast checks; do not introduce a second lint or secret-scanning policy.

## Hook installation

One `.venv/bin/python scripts/install-hooks.py` command installs checksum-pinned check tools and worktree-scoped pre-commit/pre-push launchers. Git's worktree configuration keeps other checkouts unaffected. Preserve and invoke the previous effective hooks, including global identity/leak guards. Never change Git identity or global hooks. Stable launchers live in the private Git directory and resolve the current checkout dynamically; older checkouts without the new runner still delegate to their prior hooks. Reinstallation preserves the original chain. Refuse configuration requiring unrelated worktree/bare-setting migration.

## Exact content and shared policy

Pre-commit checks an owned temporary snapshot of the index, preserving partial staging and working files. Pre-push checks each outgoing commit tree and its new history, preserving Git's ref-list input for prior hooks. Snapshots use existing Git objects and temporary index/metadata; no synthetic commits or identity settings are needed. Shared fast gates run with the configured Python and pinned tools. Missing prerequisites fail.

The stdlib sensitive-file checker rejects case-insensitive private-key extensions (`.p8`, `.pem`, `.key`, `.p12`, `.pfx`), conventional private-key names, Sparkle private/secret key names and environment files. Files above 10 MiB are rejected regardless of extension, preventing renaming from bypassing the large-binary limit; the largest existing tracked blob is about 1.15 MB. Escaping symlinks, unresolved index entries and uninspectable objects fail. Deletions are allowed, while renamed additions receive the same checks.

CI runs the same tree checks and scans every new commit between the immutable event base and head, catching sensitive files or secrets added and then deleted. Gitleaks reports are redacted, and the report output cannot be a symlink; inline allow comments cannot bypass scanning. Existing exact public-key exceptions remain. No GitHub secret-scanning or push-protection feature is involved.

## Verification

Test staged-versus-working content, real Gitleaks detection/redaction, path/size policies, deleted/renamed files, symlinks including cycles reached through directory components, push ref parsing, missing CI baselines, previous-hook chaining and worktree-only installation. Temporary repositories need no commits or identity overrides. Run focused Python tests and the shared fast entrypoint; hosted CI supplies the full build/native verification. Keep private data and unredacted findings out of logs.

References: [Git hooks](https://git-scm.com/docs/githooks), [worktree configuration](https://git-scm.com/docs/git-worktree#_configuration_file), [Gitleaks](https://github.com/gitleaks/gitleaks/tree/v8.30.1). Related: [[Notebook_Maintenance]], [[CI_Pipeline_Design]].

## Implementation

`git_content.py` supplies immutable IDs, push ref parsing and exact-content snapshots. `sensitive_files.py` is the shared metadata policy; `check-secret-history.py` applies it to every new commit before redacted Gitleaks history scanning. `ci-checks.py` runs ten gates, including these checks. Its CI checkout fetches complete history and receives the planner's immutable base. A missing CI base fails.

`hook_support.py` installs private-Git-directory launchers from `.githooks/run.sh`, saving the prior hook path in worktree configuration. Every existing executable hook receives a forwarding launcher, preserving `commit-msg` and other guards as well as pre-commit/pre-push. The runner chains prior hooks before new checks and replays push input. Push ref labels are decoded losslessly so non-UTF-8 names do not prevent the associated object IDs from being checked. Temporary snapshots reference existing Git objects; their metadata updates do not run global reference hooks. Known input/configuration failures produce concise errors.

The license-header gate reads `git ls-files -z` as bytes and uses filesystem surrogate escapes, so unusual tracked filenames do not crash path discovery. It does not accept a tracked source symlink merely because its target has an MPL header; Git stores the link text at that path.
The license-header gate reads `git ls-files -z` as bytes and uses filesystem surrogate escapes, so unusual tracked filenames do not crash path discovery. Unreadable or non-UTF-8 tracked sources fail with a concise input error rather than a traceback.

Prior hook paths use Git's path expansion, including `~/…`, rather than treating configuration values as literal repository-relative strings. A temporary-repository regression covers this without changing the home directory or identity.
The installer refuses a symlink at the private Git directory's managed hook root before writing any launcher files.

Thirteen focused tests passed, including a real redacted Gitleaks finding from staged content after the working copy was sanitized, with inline allow comments ignored. The complete ten-gate entrypoint passed 203 Python tests on the production baseline. The installer was executed in this worktree; identity/signing configuration remained byte-for-byte unchanged, and Orca still resolved the checkout. Real installed commit/push execution and hosted CI provide the remaining integration evidence.

Production integration at `70fac2e` preserves the real ephemeral-key Sparkle simulation, upgrade/property fixtures, Inspector contracts and screenshot probes. Both Commit Gates and Sparkle Update Simulation retain direct index links. The #335 workflow delta remains three fast-gate lines; app sources, engine fixture, package manifest and shipping stage match production. Integration uses a production merge commit rather than rewriting branch history. Recheck complete fast gates against the merged index before publishing; hosted CI must validate that exact merge head before re-enqueueing.

Merged-index verification passed all ten shared gate commands and 215 Python tests, including the incoming Sparkle and screenshot fixtures. Hosted verification remains required for the published merge head.
