# CI run time and retained coverage

Issue #378 targets a green app PR in at most 15 minutes, including runner queue time. This note precedes implementation. Related: [[CI_Pipeline]], [[Commit_Gates]], [[Test_Coverage]].

## Hosted baseline

[Run 41409163101](https://github.com/arcusis/shaar/actions/runs/41409163101), head `36017bf`, passed without native retries. GitHub API timestamps give 34m26s from creation to completion, including 1m52s before the first job; the executing graph took 32m34s. Swift CodeQL took 31m04s, engine build/probes 19m55s, unit build/tests 3m50s, coverage 4m43s, visuals 6m16s and shipping 4m50s. Shipping started after the engine job, although producing the candidate does not depend on probe outputs.

CodeQL's log shows an 11-minute gap before dependency resolution and a further 17m23s Swift build. The engine job spent 5m18s building, 3m41s on baseline, about 10 minutes on three independent private-window repetitions, then Quit/recovery. These are measurements, not predicted savings.

A second baseline, [#375 run 41417517803](https://github.com/arcusis/shaar/actions/runs/41417517803), passed at `9430440`: 39m07s total. Swift CodeQL took 30m04s, engine 28m27s and shipping 3m37s. This confirms variable probe/build time and the need to measure final hosted execution rather than extrapolate one run. All thirteen executed jobs passed on attempt 1.

## Implementation plan

1. Start shipping after unit success. Keep final `CI required` dependent on every selected gate, so independent candidate production cannot permit an unverified merge.
2. Build one verification bundle, archive it with permissions/symlinks intact, and verify its digest and signature when restored. Run baseline plus lifecycle checks in one shard and each private-window repetition in a separate shard. Preserve every requested iteration, the private/Quit minimum of three, fresh probe roots, failure retention and scoped evidence. No retry loops.
3. Warm SwiftPM manifests/dependencies before CodeQL initialization. Keep traced compilations fresh; cached objects cannot stand in for extraction. Measure whole-module compilation with optimization disabled, retaining all existing source modules, and fail if the extracted-file report omits a tracked Swift source. Python/Actions analysis remains. Swift analysis remains required for app/build-input changes and full production/nightly runs; proven unrelated PR diffs may skip it.
4. Use explicit Ubuntu 24.04 labels, including separate workflows. Replace dependency-review and download-artifact with verified Node 24 releases pinned by full SHA. Keep severity policy unchanged. Preserve Scorecard and production-only unsigned-candidate attestation.
5. Run shared fast gates on Ubuntu using its installed Swift formatter and checksum-pinned Linux tools. Cache Python environments by OS/architecture/requirements, SwiftPM dependencies by toolchain/lockfile, engine archives by pinned digest and pnpm stores by lockfile. Build/test commands always execute after restoration.
6. Classify only known docs/site paths as native-free. Unknown/empty diffs fail open to full work. Make website checks callable from Source checks and required for relevant PR/merge-group changes, closing the existing merge-group gap. Keep all renderer contracts, localization/unit tests, visual filters, engine probes, release guards and Sparkle simulation once merged from production.
7. Merge production into this branch after #375 lands; never rewrite published history. Publish intermediate commits and hosted measurements. Repository ruleset 26350516 already allows groups of five; this change does not edit rulesets or merge PRs.

## Coverage audit

| Area | Retained enforcement |
| --- | --- |
| Swift app/core/localization/schema | Build, all unit suites, per-module coverage no-regression, source pins, Swift CodeQL when selected |
| Native engine/private/Quit/recovery | Every existing scenario and repetition, independent shard evidence, no retries |
| Native presentation | All six hosted-only visual filters |
| Inspector renderer | Headless source-hashed renderer contracts |
| Python/scripts/hooks | All discovered Python tests, sensitive-file/history gates, shellcheck, Gitleaks, Python CodeQL |
| Workflow/configuration | actionlint, full SHA pins, Actions CodeQL, fail-closed required-stage validation |
| Website | Locked install, typecheck, tests, lint/format, build, source licenses, static and served links; required in merge groups when relevant |
| Shipping/update | Verification-code exclusion, pinned engine integrity, deep signature validation, SBOM validation; real ephemeral-key Sparkle cases inherited from #374 |
| Production/nightly | Original unsigned-candidate attestation, Scorecard, sanitizers, dead-code report and full Swift analysis |

## Sources and proof boundary

[GitHub compiled-language guidance](https://docs.github.com/en/code-security/how-tos/find-and-fix-code-vulnerabilities/manage-your-configuration/codeql-for-compiled-languages) makes manual-build coverage depend on compiled files. [CodeQL preparation](https://docs.github.com/en/code-security/tutorials/customize-code-scanning/prepare-code-for-analysis) warns that cached compilations can skip extraction. [Swift compiler documentation](https://github.com/swiftlang/swift/blob/main/docs/CompilerPerformance.md) describes whole-module compilation independently from optimization; hosted results must establish its suitability here. [Dependency review v5](https://github.com/actions/dependency-review-action/releases/tag/v5.0.0) targets Node 24. [Ubuntu image inventory](https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md) lists installed Swift; the hosted fast gate must verify the actual formatter and Linux test behavior.

After timings and annotation counts remain pending. No speed or coverage claim follows from this design alone. Local checks remain headless; native probe/visual/updater execution stays on hosted macOS.

Local implementation verification: native SwiftPM compiled all default targets with whole-module mode, `-Onone`, index store disabled and two backend threads. Explicit `-num-threads 2` preserves per-source object outputs required by SwiftPM. An initial Xcode-backend trial and a non-threaded trial failed before the passing native build; no runtime app was launched. Thirty focused pipeline tests currently pass. A hosted timing dispatch may disable only the extra sanitizer/dead-code jobs through `deep_checks=false`; its default remains true, nightly remains mandatory, and all PR gates including full Swift extraction still run.

The #375 command artifact refines the second baseline: build 315.356s, baseline 346.495s, private repetitions 335.611/334.225/324.102s, Quit 3.558/3.073/3.278s and recovery 3.566s. Shards preserve these modes/counts without changing the fixture. Local shared gates passed all ten commands and 209 Python tests. Dependency review remains enabled in merge groups: six seconds of extra work preserves review of the actual synthetic diff without assuming separate PR reviews prove equivalence.

The first hosted trial passed every engine shard, visuals and shipping within thirteen minutes, but full Swift tracing still exceeded the target. Pre-initialization dependency resolution did not solve manifest extraction. SwiftPM 6.2's [ManifestLoader cache key](https://github.com/swiftlang/swift-package-manager/blob/swift-6.2-RELEASE/Sources/PackageLoading/ManifestLoader.swift) includes the process environment; CodeQL initialization adds tracing variables, invalidating that cache. The next trial records actual native Swift driver commands from a verbose build before initialization, then runs those commands directly under CodeQL with whole-module compilation. This preserves fresh extraction of every tracked source module, including verification tools, while avoiding analysis of the SwiftPM manifest interpreter. Compiler identity, commit, source hashes and response-file source inventory must remain identical. Commands execute as argument arrays, never shell text. Missing/duplicate sources fail, and the independent CodeQL extracted-file gate still applies. Build configuration remains checked by SwiftPM itself, pin checks, formatting and Actions/Python analysis.

The compiler replay prototype passed a native build and a separate fresh replay of BrowserCore, ArcusisBrowser, Shaar and ShaarVerification, covering 213 tracked Swift files. The driver emits module and object output in one whole-module invocation with two backend threads. Local shared gates passed ten commands and 212 Python tests, including 33 pipeline tests; missing/duplicate source plans, response-file escape and source mutation are rejected. These are compile/structure checks, not hosted CodeQL proof.
