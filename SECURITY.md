# Security policy

Shaar is under active development. No fixed support window or security update
service is currently promised. The bundled Chromium engine is pinned; a pin does
not provide ongoing security updates.

## Report a vulnerability

Report suspected vulnerabilities privately through
[GitHub Security Advisories](https://github.com/arcusis/shaar/security/advisories/new).
Include affected version or commit, impact, and reproducible steps when safe.
Do not open a public issue for an unpatched vulnerability.

The maintainers will review reports and coordinate a response through the
advisory. Do not include secrets or unrelated personal information in reports.

## Accepted Scorecard findings

These OpenSSF Scorecard results stay short of a perfect score on purpose.
Each one is a posture signal about project process. Closing one by adding a
tool whose only job is to move the number is out of scope for this release.
GitHub secret scanning and push protection stay off.

Fuzzing. Shaar does not yet have a parser of its own that a fuzzer should
target. The pinned Chromium engine is already fuzzed by the Chromium project.
A placeholder fuzz target in this repository would not exercise Shaar.

CII Best Practices. The project has no OpenSSF Best Practices badge. Publishing
a badge before the criteria are met, including required review and project age,
would not make the release safer.

Maintained. Scorecard scores this at 0 until a repository is 90 days old. This
repository was created on 2026-10-24, so the score cannot rise before
2027-01-22 no matter how often the code changes. Development is active.

Code review. Recent production commits do not have a second person's approval.
During this release sprint, ruleset 26350516 stays disabled. The checked-in
ruleset requires the CI status check and the merge queue. Pull-request review
is a separate setting, and this ruleset leaves it unset. Turning the ruleset
back on remains a release action for the repository owner.

SAST and CI tests. CodeQL for Swift, Python, and Actions, and the pull-request
test workflows, are already running. Scorecard gives both checks 9 because 28
of the last 30 commits were covered. The missing two are historical. A second
scanner would not close that gap.
