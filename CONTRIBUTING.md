# Contributing

Contributions should be focused, documented where needed, and include tests for
behavior changes. Open an issue to discuss substantial changes before starting
work.

## Requirements

- macOS 26 or later on Apple silicon
- Xcode 26 and Swift 6.2 or later
- Python 3 for Python tooling

## Build and test

```sh
swift build
swift test --jobs 2
.venv/bin/python scripts/test-python.py
swift format lint --strict --recursive Package.swift Sources Tests
python3 scripts/check-license-headers.py
.venv/bin/python scripts/check-notebook-links.py
bash scripts/test-engine.sh
```

The engine test requires the pinned engine bundle. Use
`bash scripts/bundle-app.sh --with-engine` to build an app with that engine.
Read [Build and Run](Notebook/Build_And_Run.md) and
[Source and Native Verification](Notebook/Source_And_Native_Verification.md)
for setup and verification boundaries. Do not include private profiles,
credentials, or real user data in tests or reports.

## Code and documentation

Follow nearby Swift style and keep functions small and named for their purpose.
Add comments to explain why behavior is required, not to restate code. Keep
documentation accurate and free of personal data. Preserve upstream license and
notice files when changing bundled components.

Every pull request must update `Notebook/` for its changes, including tooling,
tests, CI, and documentation. Update an existing note or add a short atomic note
for each new concept. Link every note directly from at least one `_INDEX_*.md`
using a `[[Note_Name]]` wiki link; links from other notes alone do not count.
Keep index links current when renaming or removing notes. Describe behavior
present on the target branch separately from proposals in open pull requests,
and state verification limits. Run `.venv/bin/python scripts/check-notebook-links.py`
before submitting; CI rejects notes missing index links. See
[Notebook maintenance](Notebook/Notebook_Maintenance.md).

Start every new source file with the MPL-2.0 header used across the repository;
`scripts/check-license-headers.py` enforces it.

## Commit and push checks

After configuring `.venv` with the hash-pinned release requirements, install the
hooks and pinned lint/scan tools for this worktree:

```sh
.venv/bin/python scripts/install-hooks.py
```

The installer uses Git worktree configuration and preserves the previous hooks,
including global identity and leak guards. Other worktrees keep their own hook
configuration; install once in each checkout. No Git identity or global hook is
changed. A stable launcher also preserves prior guards on older checkouts that
predate this runner.

Pre-commit runs the shared fast gates against the exact index, so partial staging
and unstaged edits remain intact. Pre-push checks each outgoing tree and its new
commit history. Checks include Swift formatting, license headers, Notebook links,
actionlint, shellcheck, pins, Python tests and redacted Gitleaks scans. Run them
manually with `PATH="$PWD/build/ci-tools:$PATH" .venv/bin/python scripts/ci-checks.py`.
Missing tools fail rather than silently skipping checks.

Private-key filenames (`.p8`, `.pem`, `.key`, `.p12`, `.pfx`, conventional SSH keys
and Sparkle private/secret keys), environment files (`.env`, `.env.*`, `*.env`,
`.dev.vars`), escaping symlinks and files larger than 10 MiB are blocked. The size
limit applies regardless of extension. Store large distribution assets in releases.
CI enforces the same tree policy and scans all new commits, including files or
secrets added and deleted before the final revision. Bypassing a local hook does
not bypass those CI gates. See [Commit gates](Notebook/Commit_Gates.md).

## Changes and commits

Use imperative Conventional Commit subjects, for example:

```text
feat: add profile export
fix: preserve tab selection on restore
docs: clarify local engine build
```

Keep each change reviewable. Describe user-visible behavior, relevant tests, and
known verification limits in the pull request.
