# Parallel verification and independent Swift security

Part 2 of [#378](https://github.com/arcusis/shaar/issues/378), following merged [#380](https://github.com/arcusis/shaar/pull/380). Related: [[CI_Run_Time]], [[CI_Pipeline]], [[Test_Coverage]], [[Releasing]].

## Selected policy

The required merge graph targets under 15 minutes. Source checks retains every native build/test, strict per-module coverage gate, engine assertion/repetition, hosted visual, localization, shipping guard, ephemeral-key Sparkle simulation, and Python/Actions CodeQL check. Swift security runs independently on every PR, push and merge group. Its duration does not delay PR `CI required`.

Production pushes and nightly runs require the separate `Swift security required` result. The release workflow requires successful production-push runs of both Source checks and Swift security on the exact tagged commit, then rejects any open code-scanning alert at any severity. Missing, skipped, failed, PR, manual and other-commit results cannot satisfy the exact-commit gate. Analysis waits for SARIF processing before checking alerts. Local Developer ID/notarization/Sparkle signing and credentials are unchanged.

The 43-plus-minute full-source semantic extraction experiment was slower than production and is reverted. Restore production's compiler replay for PR shipping scope and fresh native SwiftPM full production/nightly extraction, including manifest/plugins and the existing independent extracted-file gate. The earlier production profile took about 31 minutes; the part 1 final PR Swift job took 21m16s. No unmeasured extraction optimization ships. The obsolete unapplied production-only patch is removed: the selected policy keeps Swift running on PRs.

## Engine transfer and required-failure fixes

One builder creates a commit/toolchain/engine-bound archive; baseline/lifecycle and three independent private-window shards verify its digest and deep signature before running the unchanged fixture. Private/Quit retain at least three repetitions. Every failure remains a failure; no retries. BrowserCore resolves the packaged `Contents/Resources` bundle before SwiftPM's builder-path fallback, fixing clean-consumer startup. Packaged lookup and development fallback have focused regressions.

The first transferred-bundle run [41470642284](https://github.com/arcusis/shaar/actions/runs/41470642284) passed all three private shards but exposed a media readiness race. The probe now waits for both playing state and decoded video before retaining the original non-seekable assertion. A unit regression covers paused, playing-before-video, decoded-video and paused-after-video states.

[Run 41473769184](https://github.com/arcusis/shaar/actions/runs/41473769184) passed baseline/lifecycle and two private shards. Private shard 2 recorded native cancellation failure: the first `Page.handleJavaScriptDialog` returned “no dialog,” but verification code released the CDP hold and disabled Page before beforeunload appeared. Release only after successful current-owner cancellation. A native regression verifies no-dialog and stale-owner responses retain the hold, followed by one successful release. Existing bounded polling and all private-lease assertions remain.

Strict coverage compared 678/17142 verification lines with 678/17143. The inline readiness condition added one executable line without unit execution. The extracted readiness predicate and event-order regression cover that boundary; coverage thresholds/exclusions are unchanged. Localization inventory changes contain source-line references only.

Visual/localization jobs consume no unit artifact and perform their own builds. Start after selection; coverage still waits for the unit coverage artifact. The final merge gate independently requires every selected non-Swift-security job.

## Verification and timings

Part 1 final [run 41458897983](https://github.com/arcusis/shaar/actions/runs/41458897983): green, attempt 1, **32m30s** versus **34m26s** baseline; serial engine 30m33s. The part 2 non-green trial completed its successful native gates in roughly 14 minutes while experimental Swift extraction exceeded 43 minutes. Neither failed/canceled trial establishes a green timing claim.

After reboot, local heavy commands run one at a time with `swift build/test -j 4`, starting only below one-minute load 12. Native build and all four focused regression functions passed. Policy changes pass 45 pipeline tests, actionlint, license and diff checks. Hosted final-head results remain pending. No local app or visible window was launched.

Sources: [compiled-language guidance](https://docs.github.com/en/code-security/reference/code-scanning/codeql/build-options-for-compiled-languages), [database import limitations](https://docs.github.com/en/code-security/reference/code-scanning/codeql/codeql-cli-manual/database-import).
