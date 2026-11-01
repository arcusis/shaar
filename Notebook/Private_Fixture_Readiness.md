# Private fixture readiness and confirmed cleanup

Issue #310 and the no-retry pipeline preflight exposed three ordering boundaries: a URL callback can precede completed renderer loading; a failed initial private fixture can prevent extension accounts from being seeded for restart; and a confirmed native window close can outlive the engine loop's delivery of queued host bookkeeping.

The prerequisite fix waits for the selected native private tab to satisfy the same ownership/loading predicates used by capture, without retrying capture or relaxing its checks. The probe's injected key-window identity must be weak so the fixture does not retain a closed AppKit window while checking owner deallocation. Restart must require a successful initial fixture, preserving the original failure rather than reporting missing unseeded accounts as a persistence regression.

Confirmed normal-window closure must notify the host synchronously. Native request/popup retirement remains deferred to avoid destroying engine objects in their close callback. Download fixtures pace against an elapsed-time deadline rather than accumulating one scheduling delay per chunk.

Hosted verification will run three independent private-window and Quit fixtures. Every repetition runs and any failure fails CI; these are repetitions, not retries. Local tests keep native windows hidden and never enable hosted visual flags.

Validation is pending. These changes do not address the pending-navigation engine crash in #333, real account compatibility or physical keyboard/window behavior.

Related: [[Quit_Exit_Verification]], [[Verification_Harness]], [[Source_And_Native_Verification]], [[Extension_Storage_Verification]].
