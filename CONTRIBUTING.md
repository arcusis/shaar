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

## Changes and commits

Use imperative Conventional Commit subjects, for example:

```text
feat: add profile export
fix: preserve tab selection on restore
docs: clarify local engine build
```

Keep each change reviewable. Describe user-visible behavior, relevant tests, and
known verification limits in the pull request.
