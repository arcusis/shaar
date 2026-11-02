# CI run time and retained coverage

Issue [#378](https://github.com/arcusis/shaar/issues/378) requires a green app PR within 15 minutes, including runner queue time. Design preceded implementation. Related: [[CI_Pipeline]], [[Commit_Gates]], [[Test_Coverage]], [[Releasing]].

## Measured hosted execution

Durations use GitHub run creation/completion timestamps, not the sum of job times. A failed or canceled run does not establish the green target. Every listed run used attempt 1; native fixtures have no retry path.

| Run | Profile | Wall time | Result and boundary |
| --- | --- | --- | --- |
| [41409163101](https://github.com/arcusis/shaar/actions/runs/41409163101) | Original #374 | 34m26s | Green; Swift CodeQL 31m04s, serial engine 19m55s, shipping 4m50s |
| [41417517803](https://github.com/arcusis/shaar/actions/runs/41417517803) | Original #375 | 39m07s | Green; Swift CodeQL 30m04s, serial engine 28m27s |
| [41423270716](https://github.com/arcusis/shaar/actions/runs/41423270716) | First parallel graph | 28m55s | Coverage rejected a stale source tree missing merged screenshot probes; no threshold changed |
| [41427217156](https://github.com/arcusis/shaar/actions/runs/41427217156) | Direct full-source compiler replay | 21m11s | Green; every selected gate and 215/215 Swift files |
| [41434389242](https://github.com/arcusis/shaar/actions/runs/41434389242) | Shipping plus support replay | 23m43s | Green; 178/178 Swift files; above target |
| [41437699136](https://github.com/arcusis/shaar/actions/runs/41437699136) | Planning without duplicate compilation | 18m09s | Swift passed in 17m40s, 178/178 files; Inspector restart failure kept run red |
| [41441422985](https://github.com/arcusis/shaar/actions/runs/41441422985) | Two app batches, picker acknowledgement | Canceled after >24m | Every native gate passed; Swift tracing exceeded the budget |
| Pending hosted run | Standard Intel, explicit arm64, whole-module graph | Pending | Extraction and final wall time remain unproven |

A [cold shipping-only trial](https://github.com/arcusis/shaar/actions/runs/41430145476) was canceled after exceeding the budget; it supplies no green timing claim. The original baseline included 1m52s before execution; its executing graph took 32m34s. Across measured runs, macOS build/probe durations vary substantially. Final acceptance depends on observed hosted execution.

## Pipeline structure

Start unit build, verification preparation and CodeQL immediately after stage selection. Start shipping after fast/dependency review; it consumes no unit artifact. Coverage and visuals still require unit success. `CI required` still requires every selected stage, including fast/dependency checks, probes, coverage, visuals, website checks and shipping. Independent candidate preparation cannot authorize a merge.

Build one verification bundle. Bind its archive to commit, toolchain, engine pin and SHA256; validate safe extraction and signature on each probe runner. Run baseline plus lifecycle in one shard and each private-window repetition separately. Preserve requested baseline/recovery counts and private/Quit minimum three. The normal profile executes eight probe iterations; nightly executes three of every mode; manual counts 1–10 retain exact original inventory. Every iteration runs and any failure fails. Evidence excludes browser profile directories.

Use Ubuntu 24.04 for fast gates and every Linux workflow. Dependency review v5 and download-artifact v8 use Node 24 and full SHA pins. Keep dependency severity policy and synthetic merge-group review. Cache locked Python environments, SwiftPM dependencies/products, engine archives by pin digest and pnpm stores. Always execute required build/test commands after restoration. Known docs/site PR diffs skip native work; unknown or empty diffs select full work. Website validation is required for relevant PR and merge-group changes. Ruleset 26350516 remains owner-managed: ALLGREEN groups up to five, no ruleset mutation.

## Fresh Swift extraction

SwiftPM manifest caching includes the environment; CodeQL initialization changes it. Running SwiftPM under tracing caused a long manifest-interpreter gap. Before initialization, ask native SwiftPM for its job graph, materialize declared source lists/framework copies and record compiler argument arrays. Planning creates no app objects. Bind the plan to revision, scope, compiler binary SHA256 and Git-derived source hashes. Under tracing, verify those bytes and the complete filesystem inventory without Git or compiler-lookup subprocesses.

Compile every selected module in native whole-module mode, optimization disabled, with two backend threads. Entry/verification commands follow native dependency order. The two-batch experiment was slower and is not the final strategy. Reject missing/duplicate planned sources, escaped response/output paths, graph cycles and mutated compiler/content/scope. Independently decode CodeQL's extracted-file query and require every selected Swift file.

PRs, merge groups and timing runs cover all shipping modules plus support warm-up. Production/nightly/deep manual runs cover all default-build Swift modules, including verification. Proven CI-only PRs may skip Swift analysis; source/build-input changes and unknown diffs retain it. Python and Actions analysis remain selected for native/CI work. Release procedure requires green full production Source checks before tagging; Developer ID, notarization and real Sparkle signing stay local and unchanged.

The next hardware variant runs only CodeQL Swift on standard `macos-26-intel` (4 CPUs/14 GB), leaving native build/runtime jobs on M1 `macos-26` (3 CPUs/7 GB). Both are standard public-repository runners. Explicitly compile arm64 and reject a plan targeting another architecture, preserving shipping conditional code. [GitHub runner specifications](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) establish hardware availability, not a speed claim.

The two-batch trial completed baseline/lifecycle at 13m44s, shipping at 14m38s and visuals at exactly 15m00s. Its unit job waited about 79 seconds for fast checks. Independent unit/unsigned-candidate preparation now starts earlier; the final gate still requires fast, dependency review, build and every downstream check. These changes remove idle dependencies, not validation.

## Coverage and readiness

The #375 queue baseline was correct: identical app/test source differed by three incidentally covered Quick Look cancellation/failure lines. Explicit lifecycle tests fixed that timing dependency; [#375 run 41439606539](https://github.com/arcusis/shaar/actions/runs/41439606539) passed strict coverage at 19709/33024 app lines versus 19699/33015 baseline. No epsilon, exclusion or retry was added. See [[Test_Coverage]].

The graph-only trial failed `detail selection locks` selecting `#hidden-focus` after missing-alt. `InspectorModel.pick()` queued renderer work while the probe dispatched input immediately. Return the existing task, preserve UI callback behavior and await it at each probe picker transition. A focused regression starts locked and verifies acknowledgement precedes subsequent input. Keep the original click/lock assertions and every scenario.

| Protected area | Retained gate |
| --- | --- |
| App/core/localization/schema | Native build, all unit suites, source pins, strict per-module coverage |
| Engine/private/Quit/recovery | All original scenarios and repetitions, shard evidence, no retries |
| Native presentation | All six hosted-only visual filters and real-thumbnail capture assertions |
| Inspector | Source-hashed headless renderer contracts, native input and screenshot probes |
| Python/hooks/workflows | All discovered Python tests, sensitive-file/history gates, redacted Gitleaks, formatting, license/Notebook checks, shellcheck, actionlint and SHA pins |
| Static analysis | Selected Swift extraction gate, Python/Actions CodeQL, full production/nightly Swift inventory |
| Website | Locked install, typecheck, tests, lint/format, build, licenses and static/served links |
| Shipping/update | Verification-code exclusion, pinned engine, deep signature, validated SBOM, real ephemeral-key Sparkle cases |
| Production/nightly | Unsigned-candidate provenance, Scorecard, sanitizers and dead-code report |

Local verification passed the native build, fresh full-scope replay of 216 files across five arm64 compiler commands, 41 pipeline tests, three focused test functions/four parameter cases and all ten shared gates with 231 Python tests. No local app or visible window was launched. Hosted results establish native runtime/extraction behavior separately. Final annotation audit remains pending; informational macOS capacity notices are outside the requested deprecation/migration cleanup.

Sources: [GitHub compiled-language guidance](https://docs.github.com/en/code-security/how-tos/find-and-fix-code-vulnerabilities/manage-your-configuration/codeql-for-compiled-languages), [CodeQL preparation](https://docs.github.com/en/code-security/tutorials/customize-code-scanning/prepare-code-for-analysis), [Swift compiler performance](https://github.com/swiftlang/swift/blob/main/docs/CompilerPerformance.md), [SwiftPM graph planning](https://github.com/swiftlang/swift-package-manager/blob/swift-6.3-RELEASE/Sources/Commands/SwiftBuildCommand.swift), [CodeQL extraction internals](https://github.com/github/codeql/blob/main/swift/extractor/SwiftExtractor.cpp), [dependency-review v5](https://github.com/actions/dependency-review-action/releases/tag/v5.0.0), [runner inventory](https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md).
