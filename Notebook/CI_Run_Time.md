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
| [41438505574](https://github.com/arcusis/shaar/actions/runs/41438505574) | Production with Hebrew/RTL | 42m01s | Green; Swift 29m42s, localization stage 12m10s |
| [41458897983](https://github.com/arcusis/shaar/actions/runs/41458897983) | Part 1 final integrated PR | 32m30s | Green; serial engine 30m33s, Swift CodeQL 21m16s; part 2 in [[CI_Parallel_Verification]] |
| [41482477207](https://github.com/arcusis/shaar/actions/runs/41482477207) | Part 2 required graph, head `100917f` | 14m17s | Green; all 18 selected jobs passed on attempt 1, without retries; Swift security runs independently |

A [cold shipping-only trial](https://github.com/arcusis/shaar/actions/runs/41430145476) was canceled after exceeding the budget; it supplies no green timing claim. The original baseline included 1m52s before execution; its executing graph took 32m34s. Across measured runs, macOS build/probe durations vary substantially. Final acceptance depends on observed hosted execution.

## Runner queue under concurrent PRs

Run [41556161778](https://github.com/arcusis/shaar/actions/runs/41556161778) passed in 38m34s. GitHub job `created_at` to `started_at` timestamps show 11 macOS jobs waited a combined 2h13m28s for runners (median 12m34s, maximum 23m25s). This is aggregate runner queue time across parallel jobs, not extra run wall time.

| macOS job | Queue wait | Running |
| --- | ---: | ---: |
| Fast gates | 23m25s | 1m27s |
| Build and unit tests | 2m36s | 6m54s |
| Coverage no regression | 15m08s | 6m45s |
| Hosted sidebar visuals | 21m11s | 6m36s |
| Hebrew localization | 8m45s | 14m38s |
| Engine bundle build | 4m53s | 7m27s |
| Engine baseline/lifecycle | 13m52s | 7m30s |
| Engine private-window 1 | 11m02s | 9m13s |
| Engine private-window 2 | 12m34s | 8m19s |
| Engine private-window 3 | 17m28s | 7m05s |
| Shipping bundle | 2m34s | 6m39s |

Fast gates, visuals, and coverage each waited longer than they ran. The localization and probe jobs still take substantial native execution time.

The packaged-resource source guard ignores plain `Bundle.module` text in Swift strings while checking normal and raw string interpolation and code following URL strings.
CI report collection treats malformed JUnit count attributes as report failures, keeping invalid XML metadata from crashing the summary step.

XCTest report conversion rejects durations that overflow to non-finite values.

The updated graph sends platform-independent fast checks to Ubuntu, keeps the complete Python/resource test suite on macOS, and runs the immutable-base coverage comparison in the unit-test macOS job. A docs-only fast gate runs on Ubuntu with Notebook-link, sensitive-file, secret-scan, and history checks. The sensitive-file gate rejects symlink cycles as well as links that escape the repository root. Known docs/site-only PRs select zero macOS jobs; that path has not yet had a dedicated hosted PR run.

Post-change [run 41608902696](https://github.com/arcusis/shaar/actions/runs/41608902696) passed `CI required` in 18m37s from run creation. It used 10 macOS jobs, down from 11. Their aggregate `created_at` to `started_at` wait was 61s (median 3s, maximum 29s), versus 2h13m28s (median 12m34s, maximum 23m25s) before. The wall time fell 19m57s (52%) in this before/after pair. Per-job timings:

| macOS job | Queue wait | Running |
| --- | ---: | ---: |
| Python and Apple resource tests | 3s | 1m06s |
| Build, unit tests and coverage comparison | 29s | 10m03s |
| Hosted sidebar visuals | 2s | 5m04s |
| Hebrew localization | 3s | 13m27s |
| Engine bundle build | 3s | 6m44s |
| Engine baseline/lifecycle | 2s | 9m15s |
| Engine private-window 1 | 2s | 8m06s |
| Engine private-window 2 | 2s | 7m41s |
| Engine private-window 3 | 12s | 9m36s |
| Shipping bundle | 3s | 7m58s |

This single comparison shows the queue delay was substantially reduced; the after wall time remains 3m37s above the 15-minute goal. Localization (13m27s) is now the critical path. The before and after runs had different concurrent workloads, so their wall-time change is observational rather than a controlled benchmark.

## Localization parallelism follow-up (#378)

Before changing the localization build's SwiftPM worker count, I sampled the ten newest merge-group Source checks runs on 2026-11-03. Their run-creation-to-completion wall times were 17m12s, 17m00s, 16m16s, 17m29s, 16m08s, 16m38s, 16m48s, 16m49s, 15m55s and 16m55s (median 16m48.5s; seven green, three failed). Links, in order: [41630910862](https://github.com/arcusis/shaar/actions/runs/41630910862), [41628267121](https://github.com/arcusis/shaar/actions/runs/41628267121), [41627787375](https://github.com/arcusis/shaar/actions/runs/41627787375), [41625822248](https://github.com/arcusis/shaar/actions/runs/41625822248), [41622875847](https://github.com/arcusis/shaar/actions/runs/41622875847), [41622872869](https://github.com/arcusis/shaar/actions/runs/41622872869), [41618999061](https://github.com/arcusis/shaar/actions/runs/41618999061), [41616703297](https://github.com/arcusis/shaar/actions/runs/41616703297), [41616699731](https://github.com/arcusis/shaar/actions/runs/41616699731), [41616659643](https://github.com/arcusis/shaar/actions/runs/41616659643). The current longest recurring task is the localization stage, which builds test products serially before its English/Hebrew captures and real engine-locale fixture. In run 41630910862 it occupied 16m14s; the engine graph occupied a similar interval, so both remain relevant to whole-run time.

The first hosted run after this change, [PR run 41633988050](https://github.com/arcusis/shaar/actions/runs/41633988050), passed `CI required` in 16m41s (down 7.5 seconds from the ten-run median, still above the goal). Localization completed in 10m15s, versus the previous 16m14s stage observation. The engine bundle took 7m01s and its four probe shards finished 9m17s after they started, so engine preparation and probes now set whole-run time. The PR records this comparison.

To address that remaining chain, the follow-up caches only the verification archive and metadata under the exact Git tree, engine pin, and Swift toolchain. The metadata and archive digest are revalidated on reuse, and all four engine probe shards still run. Hosted verification of this cache path is pending. No local Swift build, test suite, or engine build was run.

## Pipeline structure

Start unit build, verification preparation and CodeQL immediately after stage selection. Start shipping after fast/dependency review; it consumes no unit artifact. Coverage and visuals still require unit success. `CI required` still requires every selected stage, including fast/dependency checks, probes, coverage, visuals, website checks and shipping. Independent candidate preparation cannot authorize a merge.

Keep production's single engine job and runner unchanged: build the verification bundle and run baseline, private-window, Quit and recovery modes on the same machine. Preserve requested counts, the private/Quit minimum three, fresh roots and every failure without retries. Engine sharding and cross-runner bundle transfer are deferred to the follow-up. Shipping runs independently; final CI still requires the complete engine result.

Use Ubuntu 24.04 for every Linux workflow. Run platform-independent fast checks on Ubuntu and the complete Python/resource test suite on macOS because those tests exercise Apple's real catalog compiler. Dependency review v5 and download-artifact v8 use Node 24 and full SHA pins. Keep dependency severity policy and synthetic merge-group review. Use a separate stdlib-only Python environment for Swift CodeQL helpers; signing/release dependencies remain hash-synchronized in native/check jobs. Cache locked Python environments, SwiftPM dependencies/products, engine archives by pin digest and pnpm stores. Always execute required build/test commands after restoration. Known docs/site PR diffs skip native work and retain docs-focused fast checks; unknown or empty diffs select full work. Website validation is required for relevant PR and merge-group changes. Ruleset 26350516 remains owner-managed: ALLGREEN groups up to five, no ruleset mutation.

## Fresh Swift extraction

SwiftPM manifest caching includes the environment; CodeQL initialization changes it. Running SwiftPM under tracing caused a long manifest-interpreter gap. Before initialization, ask native SwiftPM for its job graph, materialize declared source lists/framework copies and record compiler argument arrays. Planning creates no app objects. Bind the plan to revision, scope, compiler binary SHA256 and Git-derived source hashes. Under tracing, verify those bytes and the complete filesystem inventory without Git or compiler-lookup subprocesses.

Compile every selected module in native whole-module mode, optimization disabled, with two backend threads. Entry/verification commands follow native dependency order. The two-batch experiment was slower and is not the final strategy. Reject missing/duplicate planned sources, escaped response/output paths, graph cycles and mutated compiler/content/scope. Independently decode CodeQL's extracted-file query and require every selected Swift file.

PRs, merge groups and timing runs cover all shipping modules plus support warm-up. Production/nightly/deep manual runs use fresh SwiftPM tracing for all default-build modules, the package manifest and build plugins. Manifest caching is disabled and a fresh scratch directory is required. The full extracted-file gate includes those build inputs. Proven CI-only PRs may skip Swift analysis; source/build-input changes and unknown diffs retain it. Python and Actions analysis remain selected for native/CI work. Release procedure requires green full production Source checks before tagging; Developer ID, notarization and real Sparkle signing stay local and unchanged.

The next hardware variant runs only CodeQL Swift on standard `macos-26-intel` (4 CPUs/14 GB), leaving native build/runtime jobs on M1 `macos-26` (3 CPUs/7 GB). Both are standard public-repository runners. Explicitly compile arm64 and reject a plan targeting another architecture, preserving shipping conditional code. [GitHub runner specifications](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) establish hardware availability, not a speed claim.

## CodeQL PR follow-up (#378)

The successful shipping-scope baseline [run 41538992824](https://github.com/arcusis/shaar/actions/runs/41538992824) took 30m08s for the CodeQL Swift job, including setup and analysis; traced compilation took 22m31s. Two hosted compiler experiments preserved the existing extracted-file gate but did not improve the result: two independent module jobs completed tracing in 23m45s, and allocating four threads to the serial `ArcusisBrowser` module completed tracing in 23m09s. The latter job completed in 30m24s and extracted all 200/200 selected Swift sources. The experiments are not retained as speedups.

SwiftPM dependency downloads were already cached, compiled first-party products cannot be reused without risking skipped traced source compilation, and PR analysis already uses shipping scope. Keep those boundaries. Run the PR scan only when shipping Swift or its package inputs change, and reserve full Swift scans for production pushes and nightly runs; this avoids spending a full scan on documentation/CI-only PRs and duplicate feature-branch pushes without narrowing any selected scan's source inventory. Full production/nightly analysis continues to include verification sources, the manifest, and plugins.

The two-batch trial completed baseline/lifecycle at 13m44s, shipping at 14m38s and visuals at exactly 15m00s. Its unit job waited about 79 seconds for fast checks. Independent unit/unsigned-candidate preparation now starts earlier; the final gate still requires fast, dependency review, build and every downstream check. These changes remove idle dependencies, not validation.

## Coverage and readiness

The #375 queue baseline was correct: identical app/test source differed by three incidentally covered Quick Look cancellation/failure lines. Explicit lifecycle tests fixed that timing dependency; [#375 run 41439606539](https://github.com/arcusis/shaar/actions/runs/41439606539) passed strict coverage at 19709/33024 app lines versus 19699/33015 baseline. No epsilon, exclusion or retry was added. See [[Test_Coverage]].

The graph-only trial failed `detail selection locks` selecting `#hidden-focus` after missing-alt. `InspectorModel.pick()` queued renderer work while the probe dispatched input immediately. Return the existing task, preserve UI callback behavior and await it at each probe picker transition. A focused regression starts locked and verifies acknowledgement precedes subsequent input. Keep the original click/lock assertions and every scenario.

| Protected area | Retained gate |
| --- | --- |
| App/core/localization/schema | Native build, all unit suites, source pins, strict per-module coverage, catalog validation, English/Hebrew captures and real engine locale |
| Engine/private/Quit/recovery | All original scenarios and repetitions, shard evidence, no retries |
| Native presentation | All six hosted-only visual filters and real-thumbnail capture assertions |
| Inspector | Source-hashed headless renderer contracts, native input and screenshot probes |
| Python/hooks/workflows | All discovered Python tests, sensitive-file/history gates, redacted Gitleaks, formatting, license/Notebook checks, shellcheck, actionlint and SHA pins |
| Static analysis | Selected Swift extraction gate, Python/Actions CodeQL, full production/nightly Swift inventory |
| Website | Locked install, typecheck, tests, lint/format, build, licenses and static/served links |
| Shipping/update | Verification-code exclusion, pinned engine, deep signature, validated SBOM, real ephemeral-key Sparkle cases |
| Production/nightly | Unsigned-candidate provenance, Scorecard, sanitizers and dead-code report |

Before Hebrew integration, local verification passed the native build, fresh runtime replay of 216 files, 41 pipeline tests and ten shared gates/231 Python tests. After integration, the native build, all three focused test functions/four parameter cases, fresh PR-scope replay of 187 files and a fresh full SwiftPM build passed. Current full inventory is 225 runtime files plus manifest/plugin (227); 42 pipeline tests pass. Full shared-gate and hosted extraction results remain pending. No local app or visible window was launched. Hosted results establish native runtime/extraction behavior separately. Final annotation audit remains pending; informational macOS capacity notices are outside the requested deprecation/migration cleanup.

Sources: [GitHub compiled-language guidance](https://docs.github.com/en/code-security/how-tos/find-and-fix-code-vulnerabilities/manage-your-configuration/codeql-for-compiled-languages), [CodeQL preparation](https://docs.github.com/en/code-security/tutorials/customize-code-scanning/prepare-code-for-analysis), [Swift compiler performance](https://github.com/swiftlang/swift/blob/main/docs/CompilerPerformance.md), [SwiftPM graph planning](https://github.com/swiftlang/swift-package-manager/blob/swift-6.3-RELEASE/Sources/Commands/SwiftBuildCommand.swift), [CodeQL extraction internals](https://github.com/github/codeql/blob/main/swift/extractor/SwiftExtractor.cpp), [dependency-review v5](https://github.com/actions/dependency-review-action/releases/tag/v5.0.0), [runner inventory](https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md).

Production integration includes Hebrew/RTL (`b213f63`). Preserve its localization fast check, hosted English/Hebrew captures, real engine-locale fixture, compilation plugin and final localization requirement. Resolve Inspector's button conflict by keeping the localized label and discarding the picker task in the UI callback. CodeQL follow-up work remains part of #378; this infrastructure PR does not close the issue and reports measured green wall time even before the 15-minute target is reached.

Preserve full production/nightly CodeQL compilation of the new SwiftPM localization plugin and package manifest. Full analysis uses a fresh native SwiftPM build under tracing, with manifest caching disabled; its extracted-file gate also requires `Package.swift` and `Plugins/**/*.swift`. PR shipping analysis keeps pre-initialization graph planning and fresh runtime-module replay. This retains build-configuration coverage while allowing the remaining CodeQL latency work to ship separately.

Integrated verification passed 243 Python tests and ten of eleven shared gates; the localization gate identified stale lexical line references after the Inspector edits. Regenerating `Hebrew_String_Inventory.csv` restored that gate without changing catalog translations. Native build, three focused test functions/four parameter cases, fresh 187-file shipping replay and fresh full SwiftPM build passed locally; all eleven gate commands are now verified. Hosted runtime/static-analysis results remain separate requirements.

Hosted integration exposed two setup dependencies before analysis: resource/bundle tests invoke `xcrun xcstringstool`, unavailable on Ubuntu, and the release dependency lock has no usable Intel wheel for cryptography 50.0.2. Keep the existing real compiler tests on macOS; use stdlib-only Python for CodeQL, whose helpers and localization plugin need no signing library. Native fast/shipping jobs keep the full hashed dependency sync. No test, dependency-review threshold or source-extraction requirement is removed.

## Part 1 rollout boundary

Run 41452004445 passed the non-engine gates, including Swift CodeQL, but the transferred verification bundles failed at startup in all four shards. Per the rollout decision, remove only engine sharding and its transfer helper/tests. Restore `ci-engine.yml` and `ci-stage.py` byte-for-byte from production; keep the independent shipping/build schedule, runner pins, Node 24 actions and other verified speedups. Do not change resource loading in this PR. Further sharding/CodeQL work follows after part 1 merges.

Required mergeability integration after production #376 preserves Inspector notes/copy controls, new native probes, snapshot fixtures and the new-branch immutable-base fix. Keep the picker task adapter on the localized button and regenerate only lexical inventory references. This integration resolves PR #380 conflicts; it introduces no additional pipeline tuning.

The incoming immutable-base regression still asserts the exact prior SHA. Its stage expectation follows this pipeline's stronger policy: production/native pushes always run full checks, including documentation-only diffs. PR path selection remains unchanged.
