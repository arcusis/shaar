# Private fixture readiness and confirmed cleanup

Issue #310 and the no-retry pipeline preflight exposed three ordering boundaries: a URL callback can precede completed renderer loading; a failed initial private fixture can prevent extension accounts from being seeded for restart; and a confirmed native window close can outlive the engine loop's delivery of queued host bookkeeping.

The prerequisite fix waits for the selected native private tab to satisfy the same ownership/loading predicates used by capture, without retrying capture or relaxing its checks. The probe's injected key-window identity must be weak so the fixture does not retain a closed AppKit window while checking owner deallocation. Restart must require a successful initial fixture, preserving the original failure rather than reporting missing unseeded accounts as a persistence regression.

Confirmed normal-window closure must notify the host synchronously. Native request/popup retirement remains deferred to avoid destroying engine objects in their close callback. Download fixtures pace against an elapsed-time deadline rather than accumulating one scheduling delay per chunk.

Hosted verification runs three independent private-window and Quit fixtures. Every repetition runs and any failure fails CI; these are repetitions, not retries. Local tests never enable native fixture or hosted visual flags.

Local validation built all test targets in 78.56 seconds, passed 12 focused store/host/router tests and all 164 Python tests, and passed Swift formatting, actionlint, license headers and Notebook links (43 notes/3 indexes). The two new regression tests cover elapsed pacing under coarse scheduler wakeups with exact range/byte preservation and rejection of an unseeded restart after an initial failure.

[Hosted preflight 41336411894](https://github.com/arcusis/shaar/actions/runs/41336411894) passed all five jobs on `1a6a07d`: each of three private fixtures passed 664 initial and 665 restart checks, all six Quit phases passed five checks each, baseline passed 598/599 checks, and recovery passed eight checks. Visuals and the shipping guard/signature checks passed. No failed repetition was retried. These finite results do not establish unlimited stability or address the pending-navigation engine crash in #333, real account compatibility or physical keyboard/window behavior.

The prerequisite is rebased onto production `6f89d81`, including the merged DevTools, media, launcher, indicator and tooltip changes. Their new engine probes remain intact. The earlier local/preflight results describe the preceding base; the rebased candidate requires fresh hosted validation.

Related: [[Quit_Exit_Verification]], [[Verification_Harness]], [[Source_And_Native_Verification]], [[Extension_Storage_Verification]].
