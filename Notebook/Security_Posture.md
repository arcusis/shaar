# Security posture

The accepted OpenSSF Scorecard findings, and the reason each one is accepted, are in [SECURITY.md](../SECURITY.md). This note records which alerts that decision covers.

| Check | Alert | Issue | Decision |
| --- | --- | --- | --- |
| Fuzzing | 7 | #1022 | Accept. No Shaar-owned fuzz target. |
| CII Best Practices | 5 | #1023 | Accept. No badge until the criteria are met. |
| Maintained | 4 | #1024 | Accept until 2027-01-22. The repository was created on 2026-10-24. |
| Code review | 3 | #1025 | Accept while ruleset 26350516 is disabled for the sprint. |
| SAST | 6 | none | Accept. CodeQL already covers 28 of the last 30 commits. |
| CI tests | 14 | none | Accept. Pull-request tests already cover 28 of the last 30 commits. |

Ruleset 26350516 is "Staged CI and merge queue for production". Its checked-in copy is `.github/production-ruleset.json`. Live enforcement is disabled. The ruleset requires the "CI required" status check and a merge queue. Pull-request review is unset there, so restoring the ruleset leaves the Code-Review score unchanged until commits actually receive a second person's approval. Restoring it remains a repository-owner action at release.

`scripts/check-release-ci.py` blocks a release while any code-scanning alert is open. Dismissing an accepted alert, with the reason in SECURITY.md, is what clears that gate. A later Scorecard upload can reopen an alert when GitHub treats the same finding as new.

GitHub secret scanning and push protection stay off. Release signing, the hardened runtime, helper entitlements, and the Sparkle signature check are described in [[Releasing]]. They run on the signing Mac. This repository does not contain a notarized release artifact.

Related: [[Releasing]], [[CI_Pipeline]], [[Build_And_Run]].
