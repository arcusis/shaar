# Parallel verification and Swift analysis

Part 2 of [#378](https://github.com/arcusis/shaar/issues/378), following merged [#380](https://github.com/arcusis/shaar/pull/380). Related: [[CI_Run_Time]], [[CI_Pipeline]], [[Hebrew_Localization]], [[Releasing]].

## Design before implementation

Target: a complete green hosted run below 15 minutes, including runner queue time. Keep every engine assertion and repetition, strict coverage, hosted visuals, localization, release guard and ephemeral-key Sparkle simulation. No retries or signing credentials.

1. Resolve BrowserCore resources from the packaged app's `Contents/Resources` before consulting SwiftPM's development accessor. The generated accessor searches the app root and the builder's absolute scratch path; that fallback masked a non-portable bundle on the original builder. Test packaged lookup and development fallback. Restore the commit/toolchain/engine-bound archive and independent baseline/lifecycle plus private-window shards. Consumers verify the archive digest and deep signatures before running the unchanged fixture.
2. Measure SwiftPM planning, fresh extraction and query analysis separately. Cache dependencies and SDK/compiler modules by toolchain, target and CodeQL version; never allow cached app objects to replace fresh extraction. Every PR must analyze every tracked Swift source, including verification, tests, manifest and build plugins. Keep an independent extracted-file inventory gate. Trace shipping targets efficiently, then cover remaining sources explicitly.
3. Evaluate parallel module extraction only if a combined database demonstrably preserves cross-module dataflow. GitHub's database-import documentation warns that combining partial databases can lose those relationships; separate SARIF reports do not establish equivalence. Prefer one complete database until that boundary is proven.
4. Prepare a disabled production/nightly/release-only Swift policy as a reviewable patch. Normal PR behavior remains full-source analysis. A manually selected timing run may measure the otherwise identical graph without Swift; it must be labeled a benchmark and cannot authorize a PR or release. Report both actual hosted durations, not a projected subtraction.

## Evidence

Part 1 final head `59becb2`, [run 41458897983](https://github.com/arcusis/shaar/actions/runs/41458897983): green, attempt 1, **32m30s** versus **34m26s** original baseline. Serial engine **30m33s**, Swift CodeQL **21m16s**. All 15 selected jobs passed without retries. Zero Node 20/Ubuntu migration annotations; hosted macOS capacity notices remain informational. The 15-minute goal remains open.

Part 2 timings and extraction inventories remain unverified until hosted runs complete.

Resource/shard implementation: native test build passed; both packaged-resource and development-fallback tests passed. All eleven shared fast gates passed, including 245 Python tests. The shard distribution regression checks exact scenario/iteration equality for counts 1, 2, 3 and 10; transfer regression preserves executable permissions/symlinks and rejects changed context/digest. No local app or native fixture was launched.

## Complete semantic extraction trial

Before tracing, SwiftPM builds native prerequisites with its ordinary dependency checks, using a source/toolchain-keyed cache with a same-toolchain restore prefix. Native compilation and unit execution remain separate required gates. During tracing, replay complete module inputs in fresh whole-module `-typecheck` invocations, with output/incremental flags removed. Two compiler processes share one CodeQL database; no database import or SARIF-only union is used. Manifest and plugin APIs receive explicit fresh semantic invocations. Cache SDK modules separately by extractor version/toolchain/arm64 target. Never cache a CodeQL database, project TRAP data or extraction results.

Unlike part 1, the `all` inventory includes every tracked Swift path (currently 396), including all unit tests and build configuration. Unknown Swift inputs outside the planned target/configuration graph fail preparation. Docs/site/CI PRs retain Swift analysis too. Validate commit, compiler bytes, toolchain, source hashes and response-file coverage immediately before extraction; require the independent CodeQL extracted-file query to cover the full inventory afterward.

The default manual/PR/merge-group/production/nightly path keeps Swift. `measure_without_swift=true` requires a manual dispatch with `deep_checks=false`; its final check is named `Timing only (Swift deferred)`, never `CI required`. This measures the alternate scheduling cost without enabling a PR exclusion policy.

Local preparation covered all 396 Swift files; all ten fresh semantic compiler commands passed. Forty-seven pipeline regressions and all eleven shared fast gates passed, including 248 Python tests. These checks establish command validity, not hosted CodeQL extraction or the time target.

## First clean-consumer result

[Run 41470642284](https://github.com/arcusis/shaar/actions/runs/41470642284) verifies the transferred app's deep signature and starts the actual fixture, resolving the original resource fatal error. Baseline then failed `video without a seekable duration`. The bridge reports playing state before the canvas stream has decoded dimensions (`hasVideo` requires `videoWidth > 0`); the probe waited only for playing before asserting video readiness. Wait for playing and video readiness within the existing bounded session wait, then retain the original non-seekable assertion and all later checks. This is observation synchronization, not a fixture retry. All three Quit repetitions and session recovery passed on that failed shard; its baseline failure remains recorded.

Visual and localization stages already perform their own complete test builds with separate cache modes and consume no unit artifact. Start both after stage selection; waiting for unit success adds build latency to their independent critical paths. Coverage still waits for the unit coverage artifact, and the final required check still requires unit, visuals and localization success independently.

Sources: [Swift compilation guidance](https://docs.github.com/en/code-security/reference/code-scanning/codeql/build-options-for-compiled-languages), [database import limitations](https://docs.github.com/en/code-security/reference/code-scanning/codeql/codeql-cli-manual/database-import), [database finalization](https://docs.github.com/en/code-security/reference/code-scanning/codeql/codeql-cli-manual/database-finalize).
